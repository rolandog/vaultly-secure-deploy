# shellcheck shell=bash
# sourced helpers; the caller sets PROG and VERSION

die() { printf '%s: %s\n' "${PROG:-${0##*/}}" "$*" >&2; exit 1; }
log() { printf '%s: %s\n' "${PROG:-${0##*/}}" "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
print_version() { printf '%s %s\n' "$PROG" "$VERSION"; }

# retry TRIES SECONDS CMD...  (eventual consistency: poll, don't sleep blindly)
retry() {
  local tries=$1 delay=$2 n=1
  shift 2
  until "$@"; do
    [ "$n" -ge "$tries" ] && return 1
    n=$((n + 1))
    sleep "$delay"
  done
}
