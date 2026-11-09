#!/usr/bin/env bash
# stage1-local.sh: local OpenBao dev + Vaultly proof with podman compose
set -euo pipefail; set -C

PROG=${0##*/}
VERSION=0.1.0
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
APP_DIR=$ROOT/vendor/vaultly
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

BAO_REF=quay.io/openbao/openbao:2.7.2
PY_REF=docker.io/library/python:3.12-slim
PROJECT=rg-vaultly-local
ENV_FILE=$ROOT/local/.env
EVID=$ROOT/docs/evidence
BAO_URL=http://127.0.0.1:8200
APP_URL=http://127.0.0.1:8080
COMPOSE=(podman compose -f "$ROOT/local/compose.yaml" -p "$PROJECT")

usage() {
  cat <<EOF
Usage: $PROG [--help|--version] COMMAND

Commands:
  up     resolve digests, start OpenBao (dev mode) then Vaultly
  test   run the Vaultly pytest suite against the dev server
  demo   rotate the DB secret twice and prove Vaultly never restarted
  down   remove the local stack
  all    up, test, demo

Local only: dev mode is in-memory with a root token.
EOF
}

# digest of the index, so the pin survives per-arch manifests
digest_ref() {
  local ref=$1 sum
  sum=$(skopeo inspect --raw "docker://$ref" | sha256sum | cut -d' ' -f1)
  printf '%s@sha256:%s\n' "$ref" "$sum"
}

load_env() {
  if [ ! -e "$ENV_FILE" ]; then
    (
      umask 077
      printf 'BAO_DEV_ROOT_TOKEN_ID=%s\nVAULTLY_API_BEARER_TOKEN=%s\n' \
        "$(openssl rand -hex 16)" "$(openssl rand -hex 16)" > "$ENV_FILE"
    )
  fi
  set -a
  # shellcheck source=local/.env
  . "$ENV_FILE"
  set +a
}

prepare() {
  need skopeo; need podman; need curl; need jq; need openssl
  [ -f "$APP_DIR/requirements.txt" ] || die "submodule missing: git submodule update --init"
  load_env
  BAO_IMAGE=$(digest_ref "$BAO_REF")
  PYTHON_BASE_IMAGE=$(digest_ref "$PY_REF")
  export BAO_IMAGE PYTHON_BASE_IMAGE
  mkdir -p "$EVID"
  printf '%s\n%s\n' "$BAO_IMAGE" "$PYTHON_BASE_IMAGE" | tee "$EVID/01-digests.txt"
}

# credentials go through curl -K - so they never appear in argv
bao_put() { # bao_put PATH JSON
  local body=${2//\"/\\\"}
  printf 'header = "X-Vault-Token: %s"\nheader = "Content-Type: application/json"\ndata = "%s"\n' \
    "$BAO_DEV_ROOT_TOKEN_ID" "$body" |
    curl -fsS -K - -X PUT -o /dev/null "$BAO_URL/v1/$1"
}
app_get() { # app_get PATH
  printf 'header = "Authorization: Bearer %s"\n' "$VAULTLY_API_BEARER_TOKEN" |
    curl -fsS -K - "$APP_URL/$1"
}

bao_ready() { curl -fsS -o /dev/null "$BAO_URL/v1/sys/health"; }
app_ready() { curl -fsS -o /dev/null "$APP_URL/readyz"; }
db_version() { app_get api/v1/db/status | jq -r .version; }
version_gt() { [ "$(db_version)" -gt "$1" ]; }

cmd_up() {
  prepare
  "${COMPOSE[@]}" up -d bao
  retry 30 1 bao_ready || die "openbao not ready on $BAO_URL"
  # vaultly logs in once at startup and has no retry, so bao must be ready first
  podman build --build-arg "BASE_IMAGE=$PYTHON_BASE_IMAGE" \
    -t localhost/rg-vaultly:local -f "$ROOT/container/Containerfile" "$APP_DIR"
  "${COMPOSE[@]}" up -d vaultly
  retry 30 1 app_ready || die "vaultly not ready; see: podman logs rg-vaultly-app"
  log "stack is up"
}

cmd_test() {
  prepare
  export VAULT_ADDR=$BAO_URL VAULT_TOKEN=$BAO_DEV_ROOT_TOKEN_ID
  podman run --rm --network=host --user 0:0 \
    -e VAULT_ADDR -e VAULT_TOKEN -e PYTHONDONTWRITEBYTECODE=1 \
    -v "$APP_DIR:/src:ro" -w /src "$PYTHON_BASE_IMAGE" \
    sh -c 'pip install --quiet --no-cache-dir -r requirements-dev.txt && python -m pytest -v -p no:cacheprovider' \
    2>&1 | tee "$EVID/01-pytest.txt"
  # a skipped test means the dev server was unreachable: not a pass
  if grep -Eq 'SKIPPED| skipped' "$EVID/01-pytest.txt"; then
    die "tests were skipped; the server was not reachable from the test container"
  fi
  grep -q ' passed' "$EVID/01-pytest.txt" || die "no passing tests found"
}

rotate() { # rotate: write a new random password, wait until vaultly reports a higher version
  local before
  before=$(db_version)
  LAST_PW=$(openssl rand -hex 12)
  bao_put secret/data/vaultly/database \
    "{\"data\":{\"username\":\"app_user\",\"password\":\"$LAST_PW\"}}"
  retry 30 1 version_gt "$before" || die "vaultly did not pick up the new secret in 30s"
  app_get api/v1/db/status; echo
}

cmd_demo() {
  load_env
  need curl; need jq; need openssl; need podman
  app_ready || die "vaultly is not running; run: $PROG up"
  mkdir -p "$EVID"
  {
    local t0 t1 pw1 pw2 logs
    t0=$(podman inspect --format '{{.State.StartedAt}}' rg-vaultly-app)
    printf 'container StartedAt (before): %s\n' "$t0"
    printf 'container uid: %s\n' "$(podman exec rg-vaultly-app id -u)"
    printf -- '--- status before\n'; app_get api/v1/db/status; echo
    printf -- '--- rotation 1\n'; rotate; pw1=$LAST_PW
    printf -- '--- rotation 2\n'; rotate; pw2=$LAST_PW
    t1=$(podman inspect --format '{{.State.StartedAt}}' rg-vaultly-app)
    printf 'container StartedAt (after):  %s\n' "$t1"
    [ "$t0" = "$t1" ] || die "container restarted during the demo"
    logs=$(podman logs rg-vaultly-app 2>&1)
    if grep -qF -e "$pw1" -e "$pw2" <<<"$logs"; then die "a password leaked into the logs"; fi
    printf -- '--- logs (rotation events, passwords absent)\n'
    grep -i 'rotated' <<<"$logs" | tail -n 3
    printf 'PASS: version incremented twice, StartedAt unchanged, no password in logs\n'
  } 2>&1 | tee "$EVID/01-rotation.txt"
}

cmd_down() {
  # down only needs the names; placeholders keep interpolation quiet
  BAO_IMAGE=unused PYTHON_BASE_IMAGE=unused BAO_DEV_ROOT_TOKEN_ID=unused VAULTLY_API_BEARER_TOKEN=unused \
    "${COMPOSE[@]}" down
  podman ps -a --filter name=rg-vaultly --format '{{.Names}}'
}

case "${1:-}" in
  -h|--help) usage ;;
  -V|--version) print_version ;;
  up) cmd_up ;;
  test) cmd_test ;;
  demo) cmd_demo ;;
  down) cmd_down ;;
  all) cmd_up; cmd_test; cmd_demo ;;
  *) usage >&2; exit 2 ;;
esac
