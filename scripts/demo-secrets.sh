#!/usr/bin/env bash
# demo-secrets.sh: store and read fake secrets through the Vaultly API on rg-vaultly
set -euo pipefail; set -C

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROG=${0##*/}
VERSION=0.1.0
# shellcheck source=lib.sh
. "$ROOT/scripts/lib.sh"

APP_NS=${APP_NS:-vaultly}
BAO_NS=${BAO_NS:-openbao}
BAO_POD=${BAO_POD:-openbao-0}
HOST=${DEMO_HOST:-rg-vaultly.ih.rolan.dog}
SECRET_PATH=${DEMO_SECRET_PATH:-app-config/demo-api}
DENIED_PATH=${DEMO_DENIED_PATH:-forbidden/demo-api}
# why: every patat eval block is its own process, so the fake value goes through a file
STATE=${TMPDIR:-/tmp}/rg-vaultly-demo-secret
TOKEN=
CODE=
RESP=

usage() {
  cat <<USAGE
Usage: $PROG [--help|--version] noauth|put|get|denied|delete|seed
  noauth  call the API without a token, expect a 4xx
  put     store a fake secret through Vaultly at \$DEMO_SECRET_PATH
  get     read it back and check it is the value just written
  denied  try to write outside the app's policy, expect a refusal
  delete  delete the demo secret, then show that it is gone
  seed    fallback: write the fake secret with the operator token instead of put
Env: APP_NS BAO_NS BAO_POD DEMO_HOST DEMO_SECRET_PATH DEMO_DENIED_PATH.
Needs kubectl, curl, jq (seed also needs aws).
USAGE
}

need_token() {
  TOKEN=$(kubectl -n "$APP_NS" get secret vaultly-api-bearer \
    -o jsonpath='{.data.token}' | base64 -d)
  [ -n "$TOKEN" ] || die "empty bearer token"
}

fake_value() {
  printf 'FAKE-%s\n' "$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
}

payload() {
  jq -nc --arg k "$1" '{api_key: $k, owner: "demo", note: "fake value, demo only"}'
}

# api METHOD PATH [JSON]: sets CODE and RESP; -K - keeps the token out of argv
api() {
  local method=$1 path=$2 out
  local -a data=()
  [ -z "${3:-}" ] || data=(-H 'Content-Type: application/json' --data-binary "$3")
  out=$(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" |
    curl -sS --max-time 10 -K - -X "$method" "${data[@]}" \
      -w '\n%{http_code}' "https://$HOST/api/v1/secrets/$path") || die "curl failed"
  CODE=${out##*$'\n'}
  RESP=${out%$'\n'*}
}

show() {
  echo "HTTP $CODE"
  [ -z "$RESP" ] || { printf '%s\n' "$RESP" | jq . 2>/dev/null || printf '%s\n' "$RESP"; }
}

cmd_noauth() {
  local code
  code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    "https://$HOST/api/v1/secrets/$SECRET_PATH") || die "curl failed"
  echo "no token: HTTP $code"
  case $code in 401|403) ;; *) die "expected 401 or 403" ;; esac
}

cmd_put() {
  local v body
  v=$(fake_value)
  body=$(payload "$v")
  printf '%s\n' "$v" >| "$STATE"
  echo "PUT /api/v1/secrets/$SECRET_PATH"
  echo "$body"
  api PUT "$SECRET_PATH" "$body"
  show
  case $CODE in 2??) ;; *) die "write refused (HTTP $CODE); try: $PROG seed" ;; esac
}

cmd_get() {
  local v
  [ -r "$STATE" ] || die "run put (or seed) first"
  v=$(<"$STATE")
  echo "GET /api/v1/secrets/$SECRET_PATH"
  api GET "$SECRET_PATH"
  show
  [ "$CODE" = 200 ] || die "read failed (HTTP $CODE)"
  case $RESP in
    *"$v"*) echo "round trip ok: the value written came back" ;;
    *) die "response does not contain the value written" ;;
  esac
}

cmd_denied() {
  echo "PUT /api/v1/secrets/$DENIED_PATH"
  api PUT "$DENIED_PATH" "$(payload "$(fake_value)")"
  show
  case $CODE in
    2??) die "unexpected: a write outside the policy succeeded" ;;
    *) echo "refused, as intended" ;;
  esac
}

cmd_delete() {
  echo "DELETE /api/v1/secrets/$SECRET_PATH"
  api DELETE "$SECRET_PATH"
  show
  api GET "$SECRET_PATH"
  echo "read after delete: HTTP $CODE"
}

cmd_seed() {
  local v op
  v=$(fake_value)
  printf '%s\n' "$v" >| "$STATE"
  op=$(aws ssm get-parameter --name /rg-vaultly/openbao/operator-token \
    --with-decryption --query Parameter.Value --output text)
  # why: token over stdin; the value is fake, so argv is acceptable
  printf '%s\n' "$op" |
    kubectl -n "$BAO_NS" exec -i "$BAO_POD" -- sh -c '
      read -r BAO_TOKEN; export BAO_TOKEN
      bao kv put -mount=secret "$0" api_key="$1" owner=demo note="fake value, demo only"
    ' "$SECRET_PATH" "$v" | grep -E '^(created_time|version)' || die "seed failed"
}

case ${1:-} in
  -h|--help) usage; exit 0 ;;
  -V|--version) print_version; exit 0 ;;
  noauth) cmd_noauth ;;
  put) need_token; cmd_put ;;
  get) need_token; cmd_get ;;
  denied) need_token; cmd_denied ;;
  delete) need_token; cmd_delete ;;
  seed) cmd_seed ;;
  *) usage >&2; die "need one of: noauth, put, get, denied, delete, seed" ;;
esac
