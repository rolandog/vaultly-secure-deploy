#!/usr/bin/env bash
# install-openbao.sh: OpenBao HA (raft, awskms plugin seal, TLS) on the rg-vaultly cluster
set -euo pipefail; set -C

PROG=${0##*/}
VERSION=0.1.0
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

CHART_VERSION=0.30.7
CTX=${KUBE_CONTEXT:-rg-vaultly}
NS=openbao

usage() {
  cat <<EOF
Usage: $PROG [--help|--version]

Installs or upgrades the openbao chart $CHART_VERSION with k8s/openbao/values.yaml on
kube context $CTX (override with KUBE_CONTEXT), then waits until the 3 pods are
running. Pods stay 0/1 Ready until the one-time init (stage 3c). Safe to re-run.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  -V|--version) print_version; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac
need helm; need kubectl

k() { kubectl --context "$CTX" "$@"; }

k --request-timeout=10s get --raw /readyz >/dev/null 2>&1 || die "cluster unreachable; run scripts/update-admin-ip.sh"

k -n "$NS" get secret openbao-tls >/dev/null || die "secret $NS/openbao-tls missing; run install-cert-manager.sh first"

helm repo add openbao https://openbao.github.io/openbao-helm >/dev/null
helm repo update openbao >/dev/null

k apply -f "$ROOT/k8s/openbao/storageclass.yaml"

# fail early on duplicate env names: server-side apply rejects them only at install time
dups=$(helm template openbao openbao/openbao --version "$CHART_VERSION" -n "$NS" \
  -f "$ROOT/k8s/openbao/values.yaml" -s templates/server-statefulset.yaml \
  | grep -oE '^ +- name: [A-Z][A-Z_]+$' | sort | uniq -d)
[ -z "$dups" ] || die "duplicate env in rendered statefulset: $dups"

helm upgrade --install openbao openbao/openbao --version "$CHART_VERSION" \
  --kube-context "$CTX" --namespace "$NS" \
  --values "$ROOT/k8s/openbao/values.yaml" --timeout 5m

# check every pod individually: running, not ready (ready needs init)
for i in 0 1 2; do
  ok=0
  for _ in $(seq 1 36); do
    started=$(k -n "$NS" get pod "openbao-$i" \
      -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}' 2>/dev/null || true)
    [ -n "$started" ] && { ok=1; break; }
    sleep 5
  done
  [ "$ok" -eq 1 ] || die "openbao-$i not running after 3 minutes; check kubectl describe pod"
done
log "3 pods running; next: init (stage 3c)"
