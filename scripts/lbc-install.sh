#!/usr/bin/env bash
# lbc-install.sh --- Gateway API CRDs plus AWS Load Balancer Controller (stage 4f-2)
# Re-runnable: server-side apply and helm upgrade --install are idempotent.
set -euo pipefail; set -C

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -r $ROOT/scripts/lib.sh ]]; then . "$ROOT/scripts/lib.sh"; fi

readonly INSTALL_VERSION=0.1.0
readonly PROG=${0##*/}
readonly CLUSTER=${CLUSTER:-rg-vaultly}
readonly NS=kube-system
readonly SA=aws-load-balancer-controller
readonly CHART_VERSION=3.6.2
readonly LBC_TAG=v3.6.2
readonly GWAPI_VERSION=v1.6.0
readonly VALUES=$ROOT/k8s/lbc/values.yaml
readonly GWAPI_URL=https://github.com/kubernetes-sigs/gateway-api/releases/download/$GWAPI_VERSION/standard-install.yaml
# pinned to the controller tag: the docs point at refs/heads/main, which moves
readonly LBC_CRD_URL=https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/$LBC_TAG/config/crd/gateway/gateway-crds.yaml

usage() {
  cat <<USAGE
Usage: $PROG [--help] [--version]
Install Gateway API $GWAPI_VERSION CRDs, the LBC CRDs from $LBC_TAG and chart
$CHART_VERSION of the AWS Load Balancer Controller into $NS on cluster $CLUSTER
(override with CLUSTER=). Needs the Pod Identity association from infra/eks.
USAGE
}
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
log() { printf '%s: %s\n' "$PROG" "$*"; }

for arg in "$@"; do
  case $arg in
    --help) usage; exit 0 ;;
    --version) echo "$PROG $INSTALL_VERSION"; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

for cmd in kubectl helm aws curl sha256sum; do
  command -v "$cmd" >/dev/null || die "missing command: $cmd"
done
[[ -r $VALUES ]] || die "missing $VALUES"
[[ $(kubectl config current-context) == "$CLUSTER" ]] || die "kube context is not $CLUSTER"
kubectl get nodes >/dev/null || die "cluster unreachable (try scripts/update-admin-ip.sh)"

region=$(aws configure get region || true)
region=${region:-eu-central-1}
vpc_id=$(aws eks describe-cluster --name "$CLUSTER" \
  --query cluster.resourcesVpcConfig.vpcId --output text)
[[ $vpc_id == vpc-* ]] || die "unexpected vpc id: $vpc_id"

# the identity must exist before the pods start, or they get no credentials
assoc=$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER" \
  --namespace "$NS" --service-account "$SA" \
  --query 'associations[0].associationId' --output text)
[[ -n $assoc && $assoc != None ]] || die "no pod identity association for $NS/$SA (apply infra/eks first)"
log "pod identity association $assoc, vpc $vpc_id, region $region"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/gwapi.yaml" "$GWAPI_URL"
curl -fsSL -o "$tmp/lbc-crds.yaml" "$LBC_CRD_URL"
( cd "$tmp" && sha256sum gwapi.yaml lbc-crds.yaml )

# CRDs first: the controller detects them only at start-up
kubectl apply --server-side=true -f "$tmp/gwapi.yaml"
kubectl apply --server-side=true -f "$tmp/lbc-crds.yaml"
kubectl wait --for=condition=Established --timeout=60s crd --all

helm repo add eks https://aws.github.io/eks-charts --force-update >/dev/null
helm repo update eks >/dev/null
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version="$CHART_VERSION" --namespace="$NS" --values="$VALUES" \
  --set=clusterName="$CLUSTER" --set=region="$region" --set=vpcId="$vpc_id" \
  --wait --timeout=5m

kubectl -n "$NS" rollout status deployment/aws-load-balancer-controller --timeout=180s

# check every pod: credentials come from the injected pod identity variables
mapfile -t pods < <(kubectl -n "$NS" get pods \
  -l app.kubernetes.io/name=aws-load-balancer-controller -o name)
(( ${#pods[@]} >= 1 )) || die "no controller pods found"
for p in "${pods[@]}"; do
  envs=$(kubectl -n "$NS" get "$p" -o jsonpath='{.spec.containers[0].env[*].name}')
  [[ $envs == *AWS_CONTAINER_CREDENTIALS_FULL_URI* ]] || die "$p has no pod identity credentials"
  kubectl -n "$NS" get "$p" \
    -o jsonpath='{.metadata.name}{"  "}{.status.containerStatuses[0].imageID}{"\n"}'
done
kubectl api-resources --api-group=gateway.networking.k8s.io -o name
echo "aws crds: $(kubectl get crd -o name | grep -c 'k8s\.aws' || true)"
log "ok: controller $LBC_TAG ready on $CLUSTER"
