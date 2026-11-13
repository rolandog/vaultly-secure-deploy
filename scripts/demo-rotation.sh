#!/usr/bin/env bash
# demo-rotation.sh: live secret-rotation demo on the rg-vaultly cluster
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
# why: every patat eval block is its own process, so state goes through a file
STATE=${TMPDIR:-/tmp}/rg-vaultly-demo-before
TOKEN=

usage() {
  cat <<USAGE
Usage: $PROG [--help|--version] before|rotate|after
  before  show the version served through the ALB and the pod start times
  rotate  write a new random password to secret/vaultly/database in OpenBao
  after   wait until every read shows a new version, then show the pods again
Env: APP_NS BAO_NS BAO_POD DEMO_HOST. Needs kubectl, aws, curl, jq.
USAGE
}

need_token() {
  # why: read once in the main shell; a subshell would not keep it
  TOKEN=$(kubectl -n "$APP_NS" get secret vaultly-api-bearer \
    -o jsonpath='{.data.token}' | base64 -d)
  [ -n "$TOKEN" ] || die "empty bearer token"
}

db_status() {
  # why: -K - keeps the token out of argv
  printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" |
    curl -sS --max-time 5 -K - "https://$HOST/api/v1/db/status"
}

versions() {
  local _
  for _ in $(seq 1 "$1"); do
    db_status | jq -r '.version // "none"' || echo none
  done
}

pods() {
  kubectl -n "$APP_NS" get pods -o custom-columns=POD:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,STARTED:.status.containerStatuses[0].state.running.startedAt
}

cmd_before() {
  local v
  v=$(versions 8 | sort | uniq -c)
  printf '%s\n' "$v"
  [ "$(printf '%s\n' "$v" | wc -l)" -eq 1 ] || die "pods disagree, wait 30 s and retry"
  v=$(printf '%s\n' "$v" | awk '{print $2}')
  [[ $v =~ ^[0-9]+$ ]] || die "no numeric version (401 or expired vault token?): $v"
  printf '%s\n' "$v" >| "$STATE"
  pods
}

cmd_rotate() {
  local user op
  user=$(db_status | jq -r '.username // empty')
  [ -n "$user" ] || die "app returned no username"
  op=$(aws ssm get-parameter --name /rg-vaultly/openbao/operator-token \
    --with-decryption --query Parameter.Value --output text)
  # why: token over stdin, password generated in the pod, neither is printed
  printf '%s\n' "$op" |
    kubectl -n "$BAO_NS" exec -i "$BAO_POD" -- sh -c '
      read -r BAO_TOKEN; export BAO_TOKEN
      bao kv put -mount=secret vaultly/database username="$0" \
        password="$(tr -dc a-f0-9 </dev/urandom | head -c 24)"
    ' "$user" | grep -E '^(created_time|version)' || die "write to openbao failed"
}

cmd_after() {
  local before vals start=$SECONDS _
  [ -r "$STATE" ] || die "run 'before' first"
  before=$(<"$STATE")
  for _ in $(seq 1 60); do
    vals=$(versions 8 | sort -u)
    if [[ $vals =~ ^[0-9]+$ && $vals != "$before" ]]; then
      echo "version $before -> $vals on all 8 reads, after $((SECONDS - start))s"
      pods
      return 0
    fi
    sleep 2
  done
  pods
  die "timeout: before=$before now=$(printf '%s' "$vals" | tr '\n' ' ')"
}

case ${1:-} in
  -h|--help) usage; exit 0 ;;
  -V|--version) print_version; exit 0 ;;
  before) need_token; cmd_before ;;
  rotate) need_token; cmd_rotate ;;
  after) need_token; cmd_after ;;
  *) usage >&2; die "need one of: before, rotate, after" ;;
esac
