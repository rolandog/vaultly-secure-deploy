#!/usr/bin/env bash
# vaultly-image.sh: build the vaultly image for arm64+amd64 from the vendored Dockerfile on a pinned base
set -euo pipefail; set -C

PROG=${0##*/}
VERSION=0.1.1
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

CTX=$ROOT/vendor/vaultly
BASE_FILE=$ROOT/k8s/vaultly/base-image.txt
OWNER=${REPO_OWNER:-}
REPO=${GITHUB_REPO:-vaultly-secure-deploy}
LOCAL=localhost/rg-vaultly

usage() {
  cat <<EOF
Usage: $PROG [--help|--version]

Builds linux/arm64 and linux/amd64 from vendor/vaultly/docker/Dockerfile with the base
image pinned in k8s/vaultly/base-image.txt, then checks ELF header, runtime uid and
dependency versions per architecture. Does not push.
Env: REPO_OWNER (required, for the source label), GITHUB_REPO (default $REPO),
IMAGE_TAG (default <utc date>-<short commit>[-dirty]; never reuse a pushed tag).
EOF
}

for arg in "$@"; do
  case $arg in
    -h|--help) usage; exit 0 ;;
    -V|--version) print_version; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
need podman; need git; need jq; need od
[ -n "$OWNER" ] || die "REPO_OWNER is not set"

base=$(head -n 1 "$BASE_FILE")
[[ $base =~ @sha256:[0-9a-f]{64}$ ]] || die "$BASE_FILE must end in @sha256:<64 hex>"

tag=${IMAGE_TAG:-$(date -u +%Y%m%d)-$(git -C "$ROOT" rev-parse --short=7 HEAD)}
if [ -z "${IMAGE_TAG:-}" ] && [ -n "$(git -C "$ROOT" status --porcelain -- . ':!docs/evidence')" ]; then
  tag=$tag-dirty
fi
ref=$LOCAL:$tag

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# swap only the FROM line; the vendored file stays the source of truth
sed -E "s#^FROM python:3\.12-slim( AS base)#FROM $base\1#" "$CTX/docker/Dockerfile" > "$work/Containerfile"
grep -q "^FROM $base AS base" "$work/Containerfile" || die "FROM line not substituted; vendor Dockerfile changed?"

# an existing list would get new instances appended
if podman manifest exists "$ref"; then
  podman manifest rm "$ref" >/dev/null
fi
log "building $ref from $base"
podman build --platform linux/arm64,linux/amd64 --manifest "$ref" \
  --file "$work/Containerfile" \
  --label "org.opencontainers.image.source=https://github.com/$OWNER/$REPO" \
  --label "org.opencontainers.image.revision=$(git -C "$ROOT" rev-parse HEAD)" \
  --label "org.opencontainers.image.licenses=MIT" \
  --label "org.opencontainers.image.base.name=$base" \
  "$CTX"

n=$(podman manifest inspect "$ref" | jq '.manifests | length')
[ "$n" -eq 2 ] || die "expected 2 manifests, got $n"
podman manifest inspect "$ref" | jq -r '.manifests[] | "\(.platform.os)/\(.platform.architecture) \(.digest)"'

deps='import importlib.metadata as m, platform, sys
for p in ("hvac","fastapi","uvicorn","pydantic","pydantic-settings","requests"):
    try: v = m.version(p)
    except m.PackageNotFoundError: v = "missing"
    print(f"{p}=={v}")
print("machine", platform.machine(), "python", sys.version.split()[0])'

# podman resolves a local list name to the host-native instance, so address each instance by image id
instance_id() {
  local want id d
  want=$(podman manifest inspect "$ref" | jq -r --arg a "$1" '.manifests[] | select(.platform.architecture == $a) | .digest')
  [ -n "$want" ] || return 1
  for id in $(podman images --all -q); do
    d=$(podman image inspect --format '{{.Digest}}' "$id" 2>/dev/null) || continue
    if [ "$d" = "$want" ]; then
      podman image inspect --format '{{.Id}}' "$id"
      return 0
    fi
  done
  return 1
}

for plat in linux/arm64 linux/amd64; do
  arch=${plat#*/}
  id=$(instance_id "$arch") || die "no local image matches the $plat manifest digest"
  [ "$(podman image inspect --format '{{.Architecture}}' "$id")" = "$arch" ] || die "image ${id:0:12} is not $arch"
  case $arch in arm64) want="b7 00" ;; amd64) want="3e 00" ;; esac
  cid=$(podman create --platform "$plat" "$id")
  podman cp "$cid:/usr/local/bin/python3.12" "$work/py-$arch" || { podman rm "$cid" >/dev/null; die "cannot copy interpreter from $plat"; }
  podman rm "$cid" >/dev/null
  got=$(od -An -tx1 -j18 -N2 "$work/py-$arch" | xargs)
  [ "$got" = "$want" ] || die "$plat interpreter ELF header is '$got', want '$want'"
  uid=$(podman run --rm --platform "$plat" --entrypoint id "$id" -u)
  [ "$uid" = 10001 ] || die "$plat runs as uid $uid, want 10001"
  log "$plat: image ${id:0:12}, ELF $got, uid $uid"
  podman run --rm --platform "$plat" --entrypoint python "$id" -c "$deps"
done
log "built and verified $ref; not pushed"
