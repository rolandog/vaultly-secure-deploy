#!/usr/bin/env bash
# replaces each needle by x's of equal length so scriptreplay timing stays valid
set -euo pipefail; set -C
VERSION=0.1.0
usage() { echo "usage: mask-typescript.sh [--help|--version] NEEDLES_FILE TYPESCRIPT..."; }
case ${1:-} in
  --help) usage; exit 0 ;;
  --version) echo "mask-typescript.sh $VERSION"; exit 0 ;;
esac
[ $# -ge 2 ] || { usage >&2; echo "mask-typescript.sh: need a needles file and a typescript" >&2; exit 1; }
needles=$(<"$1"); shift
for f in "$@"; do
  NEEDLES="$needles" LC_ALL=C perl -pi -e 'BEGIN { @n = grep { length } split /\n/, $ENV{NEEDLES} } for $s (@n) { $r = "x" x length($s); s/\Q$s\E/$r/g }' "$f"
done
