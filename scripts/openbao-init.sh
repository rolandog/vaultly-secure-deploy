#!/usr/bin/env bash
# openbao-init.sh: initialise OpenBao once; park recovery keys and a temporary root token in SSM
set -euo pipefail; set -C

PROG=${0##*/}
VERSION=0.1.1
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

CTX=${KUBE_CONTEXT:-rg-vaultly}
NS=${OPENBAO_NAMESPACE:-openbao}
PREFIX=${SSM_PREFIX:-/rg-vaultly/openbao}
SHARES=${RECOVERY_SHARES:-5}
THRESHOLD=${RECOVERY_THRESHOLD:-3}
REPLICAS=${OPENBAO_REPLICAS:-3}

usage() {
  cat <<EOF
Usage: $PROG [--help|--version]

Initialises openbao-0 (recovery shares $SHARES, threshold $THRESHOLD) if it is not
initialised yet, stores the recovery keys in $PREFIX/recovery-keys and the root
token in $PREFIX/root-token-temp (SecureString, tag Namespace=rg), verifies both
reads back, then waits until all $REPLICAS pods are initialised and unsealed.
Secrets are never printed. If a step after init fails, the secrets stay in a
0700 temp dir whose path is printed. Safe to re-run.
Env: KUBE_CONTEXT, OPENBAO_NAMESPACE, SSM_PREFIX, RECOVERY_SHARES,
RECOVERY_THRESHOLD, OPENBAO_REPLICAS.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  -V|--version) print_version; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac
need kubectl; need aws; need jq

# secrets only on tmpfs by default; mktemp honours an explicit TMPDIR
export TMPDIR=${TMPDIR:-/dev/shm}
umask 077
work=$(mktemp -d)
keep=0
cleanup() {
  if [ "$keep" -eq 1 ]; then
    echo "$PROG: secrets kept in $work (store them, then rm -rf it)" >&2
  else
    rm -rf "$work"
  fi
}
trap cleanup EXIT

pod_bao() { local n=$1; shift; kubectl --context "$CTX" -n "$NS" exec "openbao-$n" -- bao "$@"; }

# bao status exits 2 when sealed or uninitialised, 1 on error
status_json() {
  local out rc=0
  out=$(pod_bao "$1" status -format=json 2>|"$work/err") || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] || die "bao status failed on openbao-$1 (rc=$rc): $(cat "$work/err")"
  jq -c . <<<"$out" || die "openbao-$1 status is not json"
}

put_secret() {
  local name=$1 file=$2 got
  # tags and --overwrite exclude each other: only our own parameter is replaced
  if aws ssm get-parameter --name "$name" >/dev/null 2>&1; then
    aws ssm delete-parameter --name "$name"
  fi
  aws ssm put-parameter --name "$name" --type SecureString \
    --value "file://$file" --tags Key=Namespace,Value=rg >/dev/null
  got=$(aws ssm get-parameter --name "$name" --with-decryption --query Parameter.Value --output text)
  [ "$got" = "$(cat "$file")" ] || die "ssm read-back of $name differs"
  log "stored and verified $name"
}

kubectl --context "$CTX" --request-timeout=10s get --raw /readyz >/dev/null 2>&1 \
  || die "cluster unreachable; run scripts/update-admin-ip.sh"

st=$(status_json 0)
if jq -e '.initialized == true' <<<"$st" >/dev/null; then
  log "openbao-0 is already initialised; skipping init"
else
  pod_bao 0 operator init -recovery-shares="$SHARES" -recovery-threshold="$THRESHOLD" \
    -format=json >| "$work/init.json"
  keep=1
  jq -e --argjson n "$SHARES" '(.recovery_keys_b64 | length) == $n and (.root_token | length) > 0' \
    "$work/init.json" >/dev/null || die "unexpected init output (content not shown)"
  jq -c '.recovery_keys_b64' "$work/init.json" >| "$work/keys"
  jq -j '.root_token' "$work/init.json" >| "$work/token"
  put_secret "$PREFIX/recovery-keys" "$work/keys"
  put_secret "$PREFIX/root-token-temp" "$work/token"
  keep=0
  log "initialised; secrets removed from $work"
fi

for i in $(seq 0 $((REPLICAS - 1))); do
  ok=0
  for _ in $(seq 1 36); do
    st=$(status_json "$i" 2>/dev/null) || st='{}'
    if jq -e '.initialized == true and .sealed == false' <<<"$st" >/dev/null; then ok=1; break; fi
    sleep 5
  done
  [ "$ok" -eq 1 ] || die "openbao-$i not initialised and unsealed after 3 minutes"
  printf 'openbao-%s: %s\n' "$i" "$(jq -r '[.type, .storage_type, "ha=\(.ha_enabled)", "sealed=\(.sealed)"] | join(" ")' <<<"$st")"
done
kubectl --context "$CTX" -n "$NS" get pods
log "openbao initialised and unsealed on $REPLICAS pods"
