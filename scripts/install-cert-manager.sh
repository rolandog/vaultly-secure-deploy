#!/usr/bin/env bash
# install-cert-manager.sh: cert-manager plus the private CA for rg-vaultly
set -euo pipefail; set -C

PROG=${0##*/}
VERSION=0.1.0
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

CM_CHART=oci://quay.io/jetstack/charts/cert-manager
CM_VERSION=v1.21.3
CTX=${KUBE_CONTEXT:-rg-vaultly}

usage() {
  cat <<EOF
Usage: $PROG [--help|--version]

Installs cert-manager $CM_VERSION and applies k8s/cert-manager/pki.yaml (self-signed
root CA, ClusterIssuer) and k8s/openbao/{namespace,tls}.yaml on the kube context
$CTX (override with KUBE_CONTEXT). Safe to re-run.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  -V|--version) print_version; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac
need helm; need kubectl

# always name the context: the default context may point elsewhere
k() { kubectl --context "$CTX" "$@"; }
# the webhook and API need a moment after install (eventual consistency)
retry() {
  local n=$1 i; shift
  for ((i = 1; i <= n; i++)); do "$@" && return 0; sleep 5; done
  return 1
}

kubectl config get-contexts -o name | grep -qx "$CTX" \
  || die "kube context $CTX not found; run aws eks update-kubeconfig"
k get nodes >/dev/null || die "cluster unreachable (admin_cidr changed?)"

helm upgrade --install cert-manager "$CM_CHART" --version "$CM_VERSION" \
  --kube-context "$CTX" --namespace cert-manager --create-namespace \
  --values "$ROOT/k8s/cert-manager/values.yaml" --wait --timeout 5m

retry 6 k apply -f "$ROOT/k8s/cert-manager/pki.yaml" || die "pki apply failed"
k -n cert-manager wait --for=condition=Ready certificate/rg-vaultly-ca --timeout=120s
retry 6 k wait --for=condition=Ready clusterissuer/rg-vaultly-ca --timeout=30s

k apply -f "$ROOT/k8s/openbao/namespace.yaml"
retry 6 k apply -f "$ROOT/k8s/openbao/tls.yaml" || die "tls apply failed"
k -n openbao wait --for=condition=Ready certificate/openbao-tls --timeout=120s
log "cert-manager $CM_VERSION and pki ready"
