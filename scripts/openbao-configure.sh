#!/usr/bin/env bash
# openbao-configure.sh: kv v2, policies, kubernetes auth role, operator token; --revoke-root last
set -euo pipefail; set -C

PROG=${0##*/}
VERSION=0.1.1
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

CTX=${KUBE_CONTEXT:-rg-vaultly}
NS=${OPENBAO_NAMESPACE:-openbao}
PREFIX=${SSM_PREFIX:-/rg-vaultly/openbao}
KV=${KV_MOUNT:-secret}
AUTH=${K8S_AUTH_MOUNT:-kubernetes}
ROLE=${K8S_ROLE:-vaultly}
APP_NS=${APP_NAMESPACE:-vaultly}
APP_SA=${APP_SERVICE_ACCOUNT:-vaultly}
OP_TTL=${OPERATOR_TTL:-12h}
POLICIES=$ROOT/k8s/openbao/policies
REVOKE=0

usage() {
  cat <<EOF
Usage: $PROG [--revoke-root] [--help|--version]

Without flags, using the root token from $PREFIX/root-token-temp: enables kv v2 at
$KV/, writes the policies in k8s/openbao/policies, configures the kubernetes auth
mount and the role $ROLE (service account $APP_NS/$APP_SA), seeds $KV/vaultly/database
once, mints an orphan operator token (ttl $OP_TTL) into $PREFIX/operator-token and runs
a login self-test. Safe to re-run.
--revoke-root: revokes the root token and deletes its SSM parameter. Run it only
after the app login works: policies cannot be edited afterwards without generate-root.
Env: KUBE_CONTEXT, OPENBAO_NAMESPACE, SSM_PREFIX, KV_MOUNT, K8S_AUTH_MOUNT, K8S_ROLE,
APP_NAMESPACE, APP_SERVICE_ACCOUNT, OPERATOR_TTL.
EOF
}

for arg in "$@"; do
  case $arg in
    -h|--help) usage; exit 0 ;;
    -V|--version) print_version; exit 0 ;;
    --revoke-root) REVOKE=1 ;;
    *) usage >&2; exit 2 ;;
  esac
done
need kubectl; need aws; need jq; need openssl

export TMPDIR=${TMPDIR:-/dev/shm}
umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

kexec() { kubectl --context "$CTX" -n "$NS" exec -i openbao-0 -- "$@"; }
# the token travels on the first stdin line, never in argv; a payload may follow it
# the remote sh expands $t and "$@", not this shell
# shellcheck disable=SC2016
RUN='IFS= read -r t; BAO_TOKEN=$t; export BAO_TOKEN; exec bao "$@"'
bao_as() { local t=$1; shift; printf '%s\n' "$t" | kexec sh -c "$RUN" sh "$@"; }
bao_as_in() { local t=$1; shift; { printf '%s\n' "$t"; cat; } | kexec sh -c "$RUN" sh "$@"; }
# unauthenticated login, the jwt comes in on stdin
k8s_login() { printf '%s' "$2" | kexec bao write -format=json "auth/$AUTH/login" role="$1" jwt=-; }
ssm_has() { aws ssm get-parameter --name "$1" >/dev/null 2>&1; }
ssm_get() { aws ssm get-parameter --name "$1" --with-decryption --query Parameter.Value --output text; }

# copy of put_secret in openbao-init.sh: move both into lib.sh
put_secret() {
  local name=$1 file=$2 got
  if ssm_has "$name"; then
    aws ssm delete-parameter --name "$name"
  fi
  aws ssm put-parameter --name "$name" --type SecureString \
    --value "file://$file" --tags Key=Namespace,Value=rg >/dev/null
  got=$(ssm_get "$name")
  [ "$got" = "$(cat "$file")" ] || die "ssm read-back of $name differs"
  log "stored and verified $name"
}

operator_token_ok() {
  ssm_has "$PREFIX/operator-token" || return 1
  bao_as "$(ssm_get "$PREFIX/operator-token")" token lookup -format=json 2>/dev/null \
    | jq -e '.data.policies | index("rg-operator")' >/dev/null
}

kubectl --context "$CTX" --request-timeout=10s get --raw /readyz >/dev/null 2>&1 \
  || die "cluster unreachable; run scripts/update-admin-ip.sh"

if ! ssm_has "$PREFIX/root-token-temp"; then
  if [ "$REVOKE" -eq 1 ]; then
    log "root token already revoked"
    exit 0
  fi
  die "$PREFIX/root-token-temp missing: root token revoked? use bao operator generate-root with the recovery keys"
fi
root_tok=$(ssm_get "$PREFIX/root-token-temp")
bao_as "$root_tok" token lookup -format=json | jq -e '.data.policies | index("root")' >/dev/null \
  || die "stored token is not a root token"

if [ "$REVOKE" -eq 1 ]; then
  operator_token_ok || die "no working operator token in $PREFIX/operator-token; run without --revoke-root first"
  bao_as "$root_tok" token revoke >/dev/null
  aws ssm delete-parameter --name "$PREFIX/root-token-temp"
  if bao_as "$root_tok" token lookup >/dev/null 2>&1; then die "root token still valid after revoke"; fi
  ssm_has "$PREFIX/root-token-temp" && die "$PREFIX/root-token-temp still exists"
  operator_token_ok || die "operator token stopped working after the revoke"
  log "root token revoked, ssm parameter deleted, operator token still valid"
  exit 0
fi

# the chart binds the openbao service account to system:auth-delegator (TokenReview)
kubectl --context "$CTX" get clusterrolebinding -o json | jq -e --arg ns "$NS" \
  '[.items[] | select(.roleRef.name == "system:auth-delegator") | .subjects[]? | select(.kind == "ServiceAccount" and .namespace == $ns)] | length > 0' >/dev/null \
  || die "no system:auth-delegator binding for a service account in $NS"

mounts=$(bao_as "$root_tok" secrets list -format=json)
if jq -e --arg m "$KV/" 'has($m)' <<<"$mounts" >/dev/null; then
  jq -e --arg m "$KV/" '.[$m].type == "kv" and .[$m].options.version == "2"' <<<"$mounts" >/dev/null \
    || die "mount $KV/ exists but is not kv v2"
else
  bao_as "$root_tok" secrets enable -path="$KV" -version=2 kv >/dev/null
fi
log "kv v2 at $KV/"

for f in "$POLICIES"/*.hcl; do
  [ -e "$f" ] || die "no policy files in $POLICIES"
  name=$(basename "$f" .hcl)
  bao_as_in "$root_tok" policy write "$name" - <"$f" >/dev/null
  log "policy $name written"
done

auths=$(bao_as "$root_tok" auth list -format=json)
jq -e --arg m "$AUTH/" 'has($m)' <<<"$auths" >/dev/null \
  || bao_as "$root_tok" auth enable -path="$AUTH" kubernetes >/dev/null
# no reviewer jwt or ca: the pod's own token and ca.crt are used and re-read
bao_as "$root_tok" write "auth/$AUTH/config" kubernetes_host=https://kubernetes.default.svc:443 >/dev/null
bao_as "$root_tok" write "auth/$AUTH/role/$ROLE" \
  bound_service_account_names="$APP_SA" bound_service_account_namespaces="$APP_NS" \
  token_policies=vaultly-app token_ttl=15m token_max_ttl=1h >/dev/null
bao_as "$root_tok" read -format=json "auth/$AUTH/role/$ROLE" \
  | jq -e --arg sa "$APP_SA" --arg ns "$APP_NS" \
    '.data.token_policies == ["vaultly-app"] and .data.bound_service_account_names == [$sa] and .data.bound_service_account_namespaces == [$ns]' >/dev/null \
  || die "role $ROLE read-back differs"
log "kubernetes auth at $AUTH/, role $ROLE bound to $APP_NS/$APP_SA"

if bao_as "$root_tok" kv metadata get "$KV/vaultly/database" >/dev/null 2>&1; then
  log "$KV/vaultly/database exists, not touched"
else
  # demo credential only (no real database); never printed
  jq -nc --arg p "$(openssl rand -hex 16)" '{username: "app_user", password: $p}' \
    | bao_as_in "$root_tok" kv put "$KV/vaultly/database" - >/dev/null
  bao_as "$root_tok" kv metadata get "$KV/vaultly/database" >/dev/null || die "seeded secret not readable"
  log "seeded $KV/vaultly/database (version 1)"
fi

if operator_token_ok; then
  log "operator token already valid"
else
  # orphan: revoking the root token also revokes its children
  bao_as "$root_tok" token create -orphan -policy=rg-operator -ttl="$OP_TTL" -format=json \
    | jq -j '.auth.client_token' >| "$work/op"
  put_secret "$PREFIX/operator-token" "$work/op"
fi
op_tok=$(ssm_get "$PREFIX/operator-token")
op_caps=$(bao_as "$op_tok" token capabilities "$KV/data/vaultly/database")
case $op_caps in *update*) ;; *) die "operator cannot update $KV/data/vaultly/database: $op_caps" ;; esac
op_deny=$(bao_as "$op_tok" token capabilities sys/policies/acl/vaultly-app)
[ "$op_deny" = deny ] || die "operator can reach the policy api: $op_deny"

# login self-test with a throwaway role: proves reviewer, ca and host without the app
bao_as "$root_tok" write "auth/$AUTH/role/rg-selftest" \
  bound_service_account_names=default bound_service_account_namespaces="$NS" \
  token_policies=default token_ttl=2m >/dev/null
jwt=$(kubectl --context "$CTX" -n "$NS" create token default --duration=10m)
ok=0
for _ in $(seq 1 6); do
  if k8s_login rg-selftest "$jwt" 2>|"$work/err" | jq -e '.auth.policies | index("default")' >/dev/null; then ok=1; break; fi
  sleep 5
done
if [ "$ok" -eq 1 ]; then
  log "self-test: $NS/default logged in through $AUTH/ (token reviewer path works)"
  # same jwt against the app role must fail, and with an authorisation error
  if k8s_login "$ROLE" "$jwt" >/dev/null 2>|"$work/err"; then
    bao_as "$root_tok" delete "auth/$AUTH/role/rg-selftest" >/dev/null
    die "$NS/default can log in as $ROLE"
  fi
  grep -q 'service account name not authorized' "$work/err" || log "negative test failed for another reason: $(head -c 200 "$work/err")"
  log "self-test: $NS/default refused for role $ROLE"
fi
bao_as "$root_tok" delete "auth/$AUTH/role/rg-selftest" >/dev/null
[ "$ok" -eq 1 ] || die "self-test login failed: $(head -c 300 "$work/err")"

echo "--- summary"
echo "mounts:   $(bao_as "$root_tok" secrets list -format=json | jq -r 'keys | join(" ")')"
echo "auth:     $(bao_as "$root_tok" auth list -format=json | jq -r 'keys | join(" ")')"
echo "policies: $(bao_as "$root_tok" policy list | paste -sd' ')"
echo "role:     $(bao_as "$root_tok" read -format=json "auth/$AUTH/role/$ROLE" | jq -c '.data | {bound_service_account_names, bound_service_account_namespaces, token_policies, token_ttl, token_max_ttl}')"
echo "kv:       vaultly/database current_version=$(bao_as "$root_tok" kv metadata get -format=json "$KV/vaultly/database" | jq -r '.data.current_version')"
echo "operator: $op_caps on data/vaultly/database; $op_deny on sys/policies/acl/vaultly-app"
log "configured; run with --revoke-root after the app login works"
