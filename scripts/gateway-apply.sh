#!/usr/bin/env bash
# gateway-apply.sh --- render and apply the ALB Gateway for vaultly (stage 4f-3)
# Re-runnable: kubectl apply is idempotent; every wait is checked individually.
set -euo pipefail; set -C

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly APPLY_VERSION=0.1.1
readonly PROG=${0##*/}
readonly CLUSTER=${CLUSTER:-rg-vaultly}
readonly APP_FQDN=${APP_FQDN:-rg-vaultly.ih.rolan.dog}
readonly DIR=$ROOT/k8s/gateway
readonly TFVARS=$ROOT/infra/eks/terraform.tfvars

usage() {
  cat <<USAGE
Usage: $PROG [--help] [--version] [--render-only]
Render k8s/gateway for $APP_FQDN, apply it to cluster $CLUSTER, then wait for the
ALB, its targets and an HTTPS answer. Needs scripts/lbc-install.sh done and an
ISSUED ACM certificate. Env: CLUSTER, APP_FQDN, CERT_ARN, ADMIN_CIDR,
ALB_CIDRS (space separated public subnet CIDRs).
--render-only prints the manifests to stdout; it needs CERT_ARN, ADMIN_CIDR and
ALB_CIDRS and touches neither AWS nor the cluster.
USAGE
}
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
log() { printf '%s: %s\n' "$PROG" "$*"; }

render_only=0
for arg in "$@"; do
  case $arg in
    --help) usage; exit 0 ;;
    --version) echo "$PROG $APPLY_VERSION"; exit 0 ;;
    --render-only) render_only=1 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if (( render_only )); then
  [[ -n ${CERT_ARN:-} && -n ${ADMIN_CIDR:-} && -n ${ALB_CIDRS:-} ]] \
    || die "--render-only needs CERT_ARN, ADMIN_CIDR and ALB_CIDRS"
else
  for cmd in kubectl aws curl sed; do
    command -v "$cmd" >/dev/null || die "missing command: $cmd"
  done
  [[ $(kubectl config current-context) == "$CLUSTER" ]] || die "kube context is not $CLUSTER"
  ADMIN_CIDR=${ADMIN_CIDR:-$(sed -n 's/^admin_cidr *= *"\(.*\)"$/\1/p' "$TFVARS")}
  vpc_id=$(aws eks describe-cluster --name "$CLUSTER" \
    --query cluster.resourcesVpcConfig.vpcId --output text)
  # only an ISSUED certificate for exactly this name is usable by the listener
  CERT_ARN=${CERT_ARN:-$(aws acm list-certificates --certificate-statuses ISSUED \
    --query "CertificateSummaryList[?DomainName=='$APP_FQDN'].CertificateArn | [0]" --output text)}
  ALB_CIDRS=${ALB_CIDRS:-$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$vpc_id" "Name=tag:kubernetes.io/role/elb,Values=1" \
    --query 'Subnets[].CidrBlock' --output text)}
fi

[[ $ADMIN_CIDR =~ ^[0-9]+(\.[0-9]+){3}/32$ ]] || die "admin_cidr is not a.b.c.d/32"
[[ $CERT_ARN == arn:aws:acm:* ]] || die "no ISSUED ACM certificate for $APP_FQDN"
read -ra cidrs <<<"$ALB_CIDRS"
(( ${#cidrs[@]} >= 2 )) || die "need at least two public subnets, got: $ALB_CIDRS"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/out"
: >| "$tmp/from.txt"
for c in "${cidrs[@]}"; do
  printf '        - ipBlock:\n            cidr: %s\n' "$c" >> "$tmp/from.txt"
done
for f in "$DIR"/*.yaml; do
  sed -e "s|@APP_FQDN@|$APP_FQDN|g" -e "s|@CERT_ARN@|$CERT_ARN|g" \
      -e "s|@ADMIN_CIDR@|$ADMIN_CIDR|g" \
      -e "/@ALB_FROM@/{r $tmp/from.txt" -e d -e '}' "$f" >| "$tmp/out/${f##*/}"
done

if (( render_only )); then
  for f in "$tmp"/out/*.yaml; do echo '---'; cat "$f"; done
  exit 0
fi

# the controller reads Gateway objects only when its CRDs and pods exist
kubectl api-resources --api-group=gateway.k8s.aws -o name \
  | grep -qx loadbalancerconfigurations.gateway.k8s.aws \
  || die "LBC CRDs missing (run scripts/lbc-install.sh)"
# the manifests reference the vaultly Service, so the app must be deployed first
kubectl -n vaultly get deployment -o name | grep -qx deployment.apps/vaultly \
  || die "deployment vaultly missing (deploy the app first: README rebuild steps 2-7)"
kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=120s
kubectl -n vaultly rollout status deployment/vaultly --timeout=180s

kubectl apply -f "$tmp/out"
kubectl -n vaultly wait --for=condition=Programmed --timeout=300s gateway/vaultly

dns=$(kubectl -n vaultly get gateway vaultly -o jsonpath='{.status.addresses[0].value}')
[[ -n $dns ]] || die "gateway has no address"
arn=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?DNSName=='$dns'].LoadBalancerArn | [0]" --output text)
[[ $arn == arn:aws:elasticloadbalancing:* ]] || die "no ALB with dns name $dns"
aws elbv2 describe-load-balancers --load-balancer-arns "$arn" \
  --query 'LoadBalancers[].[LoadBalancerName,Scheme,State.Code]' --output text

mapfile -t tgs < <(aws elbv2 describe-target-groups --load-balancer-arn "$arn" \
  --query 'TargetGroups[].TargetGroupArn' --output text | tr '\t' '\n')
(( ${#tgs[@]} >= 1 )) || die "no target group on the ALB"
for tg in "${tgs[@]}"; do
  ok=0
  for _ in $(seq 1 30); do
    total=$(aws elbv2 describe-target-health --target-group-arn "$tg" \
      --query 'length(TargetHealthDescriptions)' --output text)
    bad=$(aws elbv2 describe-target-health --target-group-arn "$tg" \
      --query "length(TargetHealthDescriptions[?TargetHealth.State!='healthy'])" --output text)
    if (( total >= 1 && bad == 0 )); then ok=1; break; fi
    sleep 10
  done
  (( ok )) || die "targets not healthy in ${tg##*/}"
  aws elbv2 describe-target-health --target-group-arn "$tg" \
    --query 'TargetHealthDescriptions[].[Target.Id,Target.Port,TargetHealth.State]' --output text
done

# --connect-to tests the real hostname and certificate before DNS exists (stage 4f-4)
code=000
for _ in $(seq 1 30); do
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
    --connect-to "$APP_FQDN:443:$dns:443" "https://$APP_FQDN/healthz" 2>/dev/null || true)
  [[ $code == 200 ]] && break
  sleep 10
done
[[ $code == 200 ]] || die "https answered $code; is your public ip equal to admin_cidr?"
echo "https /healthz: $code"
redir=$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 5 \
  --connect-to "$APP_FQDN:80:$dns:80" "http://$APP_FQDN/")
echo "http /: $redir"
[[ $redir == "301 https://"* ]] || die "port 80 did not redirect to https"
log "ok: gateway programmed, targets healthy, tls answers on $APP_FQDN"
