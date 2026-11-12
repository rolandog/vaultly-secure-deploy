#!/usr/bin/env bash
# rebuild.sh: recreate network, eks and platform, then point kubectl at the cluster
set -euo pipefail; set -C

PROG=${0##*/}
VERSION=0.3.0
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

CLUSTER=${CLUSTER_NAME:-rg-vaultly}
NODES=${NODE_COUNT:-3}

usage() {
  cat <<EOF
Usage: $PROG [--help|--version]

Refreshes admin_cidr, applies the roots network, eks and platform in order (each with -auto-approve, no review), updates the kubeconfig (context $CLUSTER) and waits
for $NODES Ready nodes, then installs the load balancer controller (scripts/lbc-install.sh). Bills hourly until torn down. Env: CLUSTER_NAME, NODE_COUNT.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  -V|--version) print_version; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac
need aws; need kubectl

"$ROOT/scripts/update-admin-ip.sh"
for r in network eks platform; do
  "$ROOT/scripts/tf.sh" "$r" apply -auto-approve
done
aws eks update-kubeconfig --name "$CLUSTER" --alias "$CLUSTER" >/dev/null

ok=0
for _ in $(seq 1 36); do
  n=$(kubectl --context "$CLUSTER" get nodes --no-headers 2>/dev/null | grep -c ' Ready ' || true)
  [ "$n" -ge "$NODES" ] && { ok=1; break; }
  sleep 5
done
[ "$ok" -eq 1 ] || die "fewer than $NODES nodes Ready after 3 minutes"
kubectl --context "$CLUSTER" get nodes
"$ROOT/scripts/lbc-install.sh"
log "rebuild done"
