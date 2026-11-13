#!/usr/bin/env bash
# ci-checkov.sh --- run checkov per root, like the local checks (config file when present)
set -euo pipefail; set -C

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROG=${0##*/}
VERSION=0.1.0
# shellcheck source=lib.sh
. "$ROOT/scripts/lib.sh"

usage() {
  cat <<USAGE
Usage: $PROG [--help|--version]
Runs checkov on every root under infra/ (not infra/modules) and every directory under k8s/.
A directory with a .checkov.yaml is run with --config-file only (the file names its own
directory, skips and module download); the others run with -d and the usual flags.
USAGE
}
case ${1:-} in
  -h|--help) usage; exit 0 ;;
  -V|--version) print_version; exit 0 ;;
esac
need checkov
cd "$ROOT"

fail=0
run() { log "checkov $*"; checkov "$@" || fail=1; }

for d in infra/*/; do
  d=${d%/}
  if [ "$d" = infra/modules ]; then continue; fi
  if [ -r "$d/.checkov.yaml" ]; then
    run --config-file "$d/.checkov.yaml"
  else
    run -d "$d" --framework terraform --quiet --compact
  fi
done
for d in k8s/*/; do
  d=${d%/}
  if [ -r "$d/.checkov.yaml" ]; then
    run --config-file "$d/.checkov.yaml"
  else
    # policies/ holds OpenBao HCL, not manifests
    run -d "$d" --framework kubernetes --skip-path policies --quiet --compact
  fi
done
if [ "$fail" -ne 0 ]; then die "checkov reported failures"; fi
log "ok: checkov clean"
