#!/usr/bin/env bash
# openbao-rotate.sh: write a new version of secret/vaultly/database as the operator (stage 4e demo)
set -euo pipefail; set -C

PROG=${0##*/}
VERSION=0.1.0
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

CTX=${CTX:-rg-vaultly}
NS=${NS:-openbao}
PREFIX=${PREFIX:-/rg-vaultly/openbao}
KV=${KV:-secret}
SECRET=vaultly/database

usage() {
  cat <<EOF
Usage: $PROG [--help|--version]

Writes a new KV v2 version of $KV/$SECRET: random password, username
app_user_r<new version>. Uses the operator token from SSM $PREFIX/operator-token.
Nothing secret is printed or put in argv. Each run adds one version (not idempotent by design).
Environment: CTX=$CTX NS=$NS PREFIX=$PREFIX KV=$KV
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  -V|--version) print_version; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac
need kubectl; need aws; need jq; need openssl

kexec() { kubectl --context "$CTX" -n "$NS" exec -i openbao-0 -- "$@"; }
# the token travels on the first stdin line, never in argv; the remote sh expands $t and "$@"
# shellcheck disable=SC2016
RUN='IFS= read -r t; BAO_TOKEN=$t; export BAO_TOKEN; exec bao "$@"'
bao_as() { local t=$1; shift; printf '%s\n' "$t" | kexec sh -c "$RUN" sh "$@"; }
bao_as_in() { local t=$1; shift; { printf '%s\n' "$t"; cat; } | kexec sh -c "$RUN" sh "$@"; }

tok=$(aws ssm get-parameter --name "$PREFIX/operator-token" --with-decryption \
  --query Parameter.Value --output text) \
  || die "no operator token at $PREFIX/operator-token; run openbao-configure.sh first"
bao_as "$tok" token lookup >/dev/null 2>&1 \
  || die "operator token not valid; run openbao-configure.sh"

current() { bao_as "$tok" kv metadata get -format=json "$KV/$SECRET" | jq -r '.data.current_version'; }
cur=$(current)
next=$((cur + 1))
user="app_user_r$next"
pw=$(openssl rand -base64 24)

# env, not argv: /proc/<pid>/cmdline stays free of the password
U=$user P=$pw jq -n '{username: env.U, password: env.P}' \
  | bao_as_in "$tok" kv put "$KV/$SECRET" - >/dev/null
unset pw

got=$(current)
[ "$got" = "$next" ] || die "expected version $next, got $got"
log "wrote $KV/$SECRET version $got, username $user"
