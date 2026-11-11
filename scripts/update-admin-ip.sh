#!/usr/bin/env bash
# update-admin-ip.sh: point the EKS public API allow-list at the current public IPv4
set -euo pipefail; set -C

PROG=${0##*/}
VERSION=0.2.0
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

CLUSTER=${CLUSTER_NAME:-rg-vaultly}
CTX=${KUBE_CONTEXT:-$CLUSTER}
# target only the cluster: when it changes, the module's addons plan
# "version known after apply" and most_recent=true could upgrade them
TARGET=${EKS_TARGET:-module.eks.aws_eks_cluster.this[0]}
TFVARS="$ROOT/infra/eks/terraform.tfvars"
YES=0

usage() {
  cat <<EOF
Usage: $PROG [-y|--yes] [--help|--version]

Detects the current public IPv4, sets admin_cidr in infra/eks/terraform.tfvars and,
if the cluster exists, applies an in-place change of $TARGET only,
then checks that kubectl (context $CTX) reaches the API again.
Without a cluster it only writes the tfvars line. Refuses plans that create or
delete anything or touch other resources. Safe to re-run.
Env: CLUSTER_NAME, KUBE_CONTEXT, EKS_TARGET.
EOF
}

for arg in "$@"; do
  case $arg in
    -h|--help) usage; exit 0 ;;
    -V|--version) print_version; exit 0 ;;
    -y|--yes) YES=1 ;;
    *) usage >&2; exit 2 ;;
  esac
done
need aws; need curl; need jq; need kubectl

tf() { "$ROOT/scripts/tf.sh" eks "$@"; }

# sorted json list, "none" if the cluster does not exist, die on any other error
live_cidrs() {
  local out
  if out=$(aws eks describe-cluster --name "$CLUSTER" \
      --query 'cluster.resourcesVpcConfig.publicAccessCidrs' --output json 2>&1); then
    jq -c 'sort' <<<"$out"
  elif grep -q ResourceNotFoundException <<<"$out"; then
    echo none
  else
    die "aws eks describe-cluster failed: $out"
  fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

ip=$(curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')
# an ipv6 uplink would return an address that is not valid in a /32 rule
[[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "not an ipv4 address: '$ip'"
want="$ip/32"

have=$(sed -n 's/^admin_cidr *= *"\(.*\)"$/\1/p' "$TFVARS" 2>/dev/null || true)
live=$(live_cidrs)

if [ "$have" = "$want" ] && [ "$live" = "[\"$want\"]" ]; then
  log "admin_cidr already $want in tfvars and in aws; nothing to do"
  exit 0
fi

if [ "$have" != "$want" ]; then
  # edit only our line, other variables survive; >| because of set -C
  { grep -v '^admin_cidr *=' "$TFVARS" 2>/dev/null || true
    printf 'admin_cidr = "%s"\n' "$want"; } >| "$work/tfvars"
  mv -f "$work/tfvars" "$TFVARS"
  log "tfvars: admin_cidr ${have:-unset} -> $want"
fi

if [ "$live" = none ]; then
  log "cluster $CLUSTER does not exist; tfvars updated, nothing to apply"
  exit 0
fi

state=$(tf state list)
grep -qxF "$TARGET" <<<"$state" || die "$TARGET not in state; set EKS_TARGET (tofu state list)"

tf plan -target="$TARGET" -out="$work/eks.tfplan"
tf show -json "$work/eks.tfplan" | grep '^{' >| "$work/plan.json"

bad=$(jq -r '.resource_changes[]? | select(.change.actions | index("create") or index("delete")) | .address' "$work/plan.json")
[ -z "$bad" ] || die "plan creates or deletes resources, refusing: $bad"

other=$(jq -r --arg t "$TARGET" '.resource_changes[]? | select(.address != $t) | select(.change.actions | . != ["no-op"] and . != ["read"]) | .address' "$work/plan.json")
[ -z "$other" ] || die "plan changes resources besides the target, refusing: $other"

changes=$(jq -r '.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"]) | . as $r | ($r.change.before // {}) as $b | ($r.change.after // {}) as $a | ($r.change.after_unknown // {}) as $u | ([($a|keys[]), ($b|keys[])] | unique | map(select($b[.] != $a[.] or ($u[.] // false) != false))) as $k | "\($r.change.actions|join(",")) \($r.address): \($k|join(" "))"' "$work/plan.json")
if [ -z "$changes" ]; then
  die "plan is empty but aws has $live; is admin_cidr wired into $TARGET?"
fi
printf 'in-place changes (attributes):\n%s\n' "$changes"
jq -r --arg t "$TARGET" '.resource_changes[]? | select(.address == $t) | "cidrs: \((try .change.before.vpc_config[0].public_access_cidrs catch null) // "n/a") -> \((try .change.after.vpc_config[0].public_access_cidrs catch null) // "n/a")"' "$work/plan.json"

if [ "$YES" -ne 1 ]; then
  read -rp "apply this plan? [y/N] " a
  [ "$a" = y ] || die "aborted; tfvars is already updated, re-run to continue"
fi
tf apply "$work/eks.tfplan"
aws eks wait cluster-active --name "$CLUSTER"

# verify after the mutation; the allow-list and the endpoint can lag the apply
ok=0
for _ in $(seq 1 24); do
  [ "$(live_cidrs)" = "[\"$want\"]" ] && { ok=1; break; }
  sleep 5
done
[ "$ok" -eq 1 ] || die "aws allow-list is not [$want] after apply"

ok=0
for _ in $(seq 1 24); do
  kubectl --context "$CTX" --request-timeout=5s get --raw /readyz >/dev/null 2>&1 && { ok=1; break; }
  sleep 5
done
[ "$ok" -eq 1 ] || die "api server still unreachable from $ip"
kubectl --context "$CTX" get nodes
log "admin ip $ip active"
