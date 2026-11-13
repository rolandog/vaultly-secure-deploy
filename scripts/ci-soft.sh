#!/usr/bin/env bash
# ci-soft.sh LABEL CMD... --- run a scanner on the submodule; warn instead of fail
# unless SUBMODULE_GATE=true. A crash and a finding both count as a failure.
set -euo pipefail; set -C

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROG=${0##*/}
VERSION=0.1.0
# shellcheck source=lib.sh
. "$ROOT/scripts/lib.sh"

usage() {
  cat <<USAGE
Usage: $PROG [--help|--version] LABEL COMMAND [ARG...]
Runs COMMAND. On failure: exit with its status if SUBMODULE_GATE=true, otherwise
print a GitHub warning annotation and exit 0.
USAGE
}

case ${1:-} in
  -h|--help) usage; exit 0 ;;
  -V|--version) print_version; exit 0 ;;
esac
[ "$#" -ge 2 ] || { usage >&2; die "need a label and a command"; }

label=$1
shift
rc=0
"$@" || rc=$?
if [ "$rc" -eq 0 ]; then exit 0; fi
if [ "${SUBMODULE_GATE:-false}" = true ]; then die "$label failed (exit $rc), SUBMODULE_GATE=true"; fi
printf '::warning title=%s (submodule)::exit %s, not blocking (SUBMODULE_GATE=%s)\n' \
  "$label" "$rc" "${SUBMODULE_GATE:-false}"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf -- '- warning: **%s** exited %s (not blocking)\n' "$label" "$rc" >> "$GITHUB_STEP_SUMMARY"
fi
exit 0
