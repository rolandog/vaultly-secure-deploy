#!/usr/bin/env bash
# gateway-teardown.sh --- delete the Gateway, wait for the ALB and LBC security groups to vanish
set -euo pipefail; set -C

readonly TEARDOWN_VERSION=0.1.0
readonly PROG=${0##*/}
readonly CLUSTER=${CLUSTER:-rg-vaultly}

usage() {
  cat <<USAGE
Usage: $PROG [--help] [--version]
Delete the vaultly HTTPRoutes and Gateway while the controller still runs, then
wait until the ALB and the security groups tagged elbv2.k8s.aws/cluster=$CLUSTER
are gone. Run before deleting the namespace, the controller or the cluster.
USAGE
}
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
log() { printf '%s: %s\n' "$PROG" "$*"; }

case "${1:-}" in
  --help) usage; exit 0 ;;
  --version) echo "$PROG $TEARDOWN_VERSION"; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

wait_until() { # tries seconds command...
  local n=$1 s=$2 i
  shift 2
  for ((i = 0; i < n; i++)); do
    if "$@"; then return 0; fi
    sleep "$s"
  done
  return 1
}
alb_gone() {
  local n
  n=$(aws elbv2 describe-load-balancers \
    --query "length(LoadBalancers[?DNSName=='$1'])" --output text) || return 1
  [[ $n == 0 ]]
}
sgs_gone() {
  local n
  n=$(aws ec2 describe-security-groups \
    --filters "Name=tag:elbv2.k8s.aws/cluster,Values=$CLUSTER" \
    --query 'length(SecurityGroups)' --output text) || return 1
  [[ $n == 0 ]]
}

for cmd in kubectl aws; do command -v "$cmd" >/dev/null || die "missing command: $cmd"; done
[[ $(kubectl config current-context) == "$CLUSTER" ]] || die "kube context is not $CLUSTER"

dns=
if kubectl api-resources --api-group=gateway.networking.k8s.io -o name \
  | grep -qx gateways.gateway.networking.k8s.io; then
  dns=$(kubectl -n vaultly get gateway vaultly \
    -o jsonpath='{.status.addresses[0].value}' --ignore-not-found)
  kubectl -n vaultly delete httproute,gateway --all --ignore-not-found --timeout=180s \
    || die "gateway deletion timed out; check: kubectl -n kube-system logs deploy/aws-load-balancer-controller"
else
  log "gateway api not installed, nothing to delete"
fi

if [[ -n $dns ]]; then
  wait_until 36 5 alb_gone "$dns" || die "ALB still exists: $dns"
  log "ALB gone"
fi
wait_until 36 5 sgs_gone || die "security groups tagged elbv2.k8s.aws/cluster=$CLUSTER remain"
log "ok: no ALB and no controller security groups for $CLUSTER"
