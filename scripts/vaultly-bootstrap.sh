#!/usr/bin/env bash
# vaultly-bootstrap.sh: create namespace, CA ConfigMap and bearer Secret (idempotent)
set -euo pipefail; set -C

PROG=${0##*/}
VERSION=0.1.1
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly PROG VERSION ROOT
readonly NS=vaultly SRC_NS=openbao SRC_SECRET=openbao-tls

# shellcheck source=lib.sh
. "$ROOT/scripts/lib.sh"

usage() {
  cat <<USAGE
Usage: $PROG [--help] [--version]
Create namespace $NS, ConfigMap vaultly-ca (ca.crt from $SRC_NS/$SRC_SECRET) and
Secret vaultly-api-bearer (random, only created if missing) in the current kube context.
USAGE
}

case ${1:-} in
  --help)    usage; exit 0 ;;
  --version) print_version; exit 0 ;;
  '')        ;;
  *)         usage >&2; die "unrecognized option '$1'" ;;
esac

need kubectl; need base64; need od
log "context $(kubectl config current-context)"

kubectl apply -f "$ROOT/k8s/vaultly/namespace.yaml"

# the CA is public; copy it so the app trusts OpenBao's private issuer
ca=$(kubectl -n "$SRC_NS" get secret "$SRC_SECRET" -o jsonpath='{.data.ca\.crt}' | base64 -d)
grep -q 'BEGIN CERTIFICATE' <<<"$ca" || die "no ca.crt in $SRC_NS/$SRC_SECRET"
kubectl -n "$NS" create configmap vaultly-ca --from-literal=ca.crt="$ca" \
  --dry-run=client -o yaml | kubectl apply -f -

# never rotate on re-run: only create when absent
if kubectl -n "$NS" get secret vaultly-api-bearer >/dev/null 2>&1; then
  log "secret vaultly-api-bearer exists, left unchanged"
else
  # token goes through stdin so it never shows in ps or shell history
  head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' \
    | kubectl -n "$NS" create secret generic vaultly-api-bearer --from-file=token=/dev/stdin
fi

# verify without printing the secret: length only; captured first to avoid SIGPIPE under pipefail
check_secret() {
  local enc
  enc=$(kubectl -n "$NS" get secret vaultly-api-bearer -o jsonpath='{.data.token}')
  [ "$(base64 -d <<<"$enc" | wc -c)" -ge 32 ]
}
check_ca() {
  local cm
  cm=$(kubectl -n "$NS" get configmap vaultly-ca -o jsonpath='{.data.ca\.crt}')
  grep -q 'BEGIN CERTIFICATE' <<<"$cm"
}
retry 5 2 check_secret || die "vaultly-api-bearer missing or shorter than 32 bytes"
retry 5 2 check_ca     || die "vaultly-ca has no certificate"
log "ok (bearer present, >= 32 bytes; ca configmap present)"
