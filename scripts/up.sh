#!/usr/bin/env bash
# up.sh --- build the whole rg-vaultly stack from nothing and check it (stage 4g)
# Each step is a script that passed on its own; this only orders, times and checks them.
set -euo pipefail; set -C

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly UP_VERSION=0.1.0
readonly PROG=${0##*/}
readonly CLUSTER=${CLUSTER:-rg-vaultly}
STEPS=(rebuild cert-manager openbao init configure bootstrap app gateway dns verify)

usage() {
  cat <<USAGE
Usage: $PROG [--help] [--version] [--list] [--from STEP] [--revoke-root]
Build $CLUSTER from nothing: cluster, cert-manager, OpenBao, the app, the ALB gateway
and the DNS alias, then check the result. Bills hourly until scripts/teardown.sh.
--from STEP     resume at STEP after a failure (earlier steps are assumed done)
--revoke-root   run scripts/openbao-configure.sh --revoke-root as the last step
Steps: ${STEPS[*]}
USAGE
}
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
log() { printf '%s: %s\n' "$PROG" "$*"; }

from=${STEPS[0]}
revoke=0
while (( $# )); do
  case $1 in
    -h|--help) usage; exit 0 ;;
    -V|--version) echo "$PROG $UP_VERSION"; exit 0 ;;
    --list) printf '%s\n' "${STEPS[@]}"; exit 0 ;;
    --from) [[ $# -ge 2 ]] || die "--from needs a step name"; from=$2; shift ;;
    --revoke-root) revoke=1 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done
if (( revoke )); then STEPS+=(revoke-root); fi
printf '%s\n' "${STEPS[@]}" | grep -qx -- "$from" || die "unknown step: $from (see --list)"

for c in aws kubectl helm tofu jq curl; do
  command -v "$c" >/dev/null || die "missing tool: $c"
done
aws sts get-caller-identity --query Account --output text >/dev/null \
  || die "aws credentials do not work"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

step_rebuild() {
  # a half-built cluster needs a decision from you, not a blind second apply
  if aws eks describe-cluster --name "$CLUSTER" >/dev/null 2>&1; then
    die "cluster $CLUSTER exists; resume with --from or run scripts/teardown.sh"
  fi
  "$ROOT/scripts/rebuild.sh"
}
step_cert_manager() { "$ROOT/scripts/install-cert-manager.sh"; }
step_openbao() {
  "$ROOT/scripts/install-openbao.sh" 2>&1 | tee "$tmp"
  if grep -q 'would violate PodSecurity' "$tmp"; then
    log "psa: warning still printed by helm"
  else
    log "psa: no warning printed"
  fi
}
step_init() { "$ROOT/scripts/openbao-init.sh"; }
step_configure() { "$ROOT/scripts/openbao-configure.sh"; }
step_bootstrap() { "$ROOT/scripts/vaultly-bootstrap.sh"; }
step_app() {
  kubectl apply -f "$ROOT/k8s/vaultly/"
  kubectl rollout status -f "$ROOT/k8s/vaultly/deployment.yaml" --timeout=180s
}
step_gateway() { "$ROOT/scripts/gateway-apply.sh"; }
step_dns() { "$ROOT/scripts/tf.sh" app-dns apply -auto-approve; }
step_verify() {
  local i drop ready code fqdn n alb zone rcode ip
  for i in 0 1 2; do
    kubectl -n openbao wait --for=condition=Ready "pod/openbao-$i" --timeout=60s
    drop=$(kubectl -n openbao get "pod/openbao-$i" \
      -o jsonpath='{.spec.containers[?(@.name=="openbao")].securityContext.capabilities.drop[*]}')
    [[ $drop == ALL ]] || die "openbao-$i: capabilities.drop is '$drop', expected ALL"
    log "openbao-$i: ready, drops ALL"
  done
  # exec into the pod: no port-forward, no dependency on the route paths
  ready=$(kubectl -n vaultly exec deploy/vaultly -- python -c \
    "import urllib.request as u; print(u.urlopen('http://127.0.0.1:8080/readyz').read().decode())")
  jq -e '.vault_authenticated == true' <<<"$ready" >/dev/null || die "readyz: $ready"
  log "vaultly readyz: $ready"
  fqdn=$("$ROOT/scripts/tf.sh" app-dns output -raw app_fqdn)
  alb=$("$ROOT/scripts/tf.sh" app-dns output -raw alb_dns_name)
  zone=$(aws route53 list-hosted-zones-by-name --dns-name "${fqdn#*.}" --max-items 1 \
    --query 'HostedZones[0].Id' --output text || true)
  rcode=$(aws route53 test-dns-answer --hosted-zone-id "${zone##*/}" --record-name "$fqdn" \
    --record-type A --query ResponseCode --output text 2>/dev/null || echo unavailable)
  log "route 53 test-dns-answer: $rcode"
  # --resolve skips the local resolver, which may hold a negative answer for up to 15 min
  code=000
  for n in $(seq 1 12); do
    ip=$(getent ahostsv4 "$alb" | awk 'NR==1 {print $1}' || true)
    if [[ -n $ip ]]; then
      code=$(curl -sS -o /dev/null --connect-timeout 10 -m 20 -w '%{http_code}' --resolve "$fqdn:443:$ip" "https://$fqdn/healthz" || true)
    fi
    if [[ $code == 200 ]]; then break; fi
    sleep 10
  done
  [[ $code == 200 ]] || die "https://$fqdn/healthz answered '$code' via $alb (000: does the ALB security group admit your current ip? see update-admin-ip.sh and gateway-apply.sh)"
  log "https $fqdn/healthz: 200 (through the ALB address)"
  if getent hosts "$fqdn" >/dev/null; then
    log "local resolver: ok"
  else
    log "warning: local resolver has no answer yet (negative cache; see README Troubleshooting)"
  fi
}
step_revoke_root() { "$ROOT/scripts/openbao-configure.sh" --revoke-root; }

started=$SECONDS
active=0
for s in "${STEPS[@]}"; do
  if [[ $s == "$from" ]]; then active=1; fi
  if (( ! active )); then continue; fi
  t0=$SECONDS
  log "step $s: start"
  "step_${s//-/_}"
  log "step $s: ok ($(( SECONDS - t0 )) s)"
done
log "ok: $CLUSTER is up ($(( SECONDS - started )) s); tear down with scripts/teardown.sh"
