#!/usr/bin/env bash
# redact-evidence.sh: replace known identifiers in docs/ evidence with placeholders
set -euo pipefail; set -C

PROG=${0##*/}
VERSION=0.1.0
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

usage() {
  cat <<EOF
Usage: $PROG [--help|--version] [--check]

Replaces the account id and the admin IP (from infra/eks/terraform.tfvars) in
docs/evidence/*.txt and docs/*.md, plus extra "needle<TAB>replacement" lines
from local/redact.list (git-ignored). Exact strings only, never a generic regex.
--check changes nothing and fails if a known value is still present.
--learn runs gitleaks on docs/ and appends every secret it reports to local/redact.list;
run the script again without it to apply them.
EOF
}

mode=redact
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  -V|--version) print_version; exit 0 ;;
  --check) mode=check ;;
  --learn) mode=learn ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac
need aws; need perl

if [ "$mode" = learn ]; then
  need gitleaks; need jq
  umask 077
  rep=$(mktemp "${TMPDIR:-/tmp}/redact.XXXXXX")
  trap 'rm -f "$rep"' EXIT
  gitleaks detect --no-git --source "$ROOT/docs" --no-banner --report-format json \
    --report-path "$rep" --exit-code 0 >/dev/null 2>&1 || true
  mkdir -p "$ROOT/local"
  jq -r '.[]? | [.Secret, "<redacted-id>"] | @tsv' "$rep" | sort -u >> "$ROOT/local/redact.list"
  log "needles appended to local/redact.list; run again without --learn"
  exit 0
fi

needles=() repls=()
add() { [ -n "$1" ] && { needles+=("$1"); repls+=("$2"); }; return 0; }

add "$(aws sts get-caller-identity --query Account --output text)" '<account-id>'
if [ -r "$ROOT/infra/eks/terraform.tfvars" ]; then
  add "$(sed -n 's/^admin_cidr *= *"\(.*\)\/32".*/\1/p' "$ROOT/infra/eks/terraform.tfvars")" '<admin-ip>'
fi
if [ -r "$ROOT/local/redact.list" ]; then
  while IFS=$'\t' read -r n r; do add "$n" "$r"; done < "$ROOT/local/redact.list"
fi
[ "${#needles[@]}" -gt 0 ] || die "nothing to redact"

shopt -s nullglob
files=("$ROOT"/docs/evidence/*.txt "$ROOT"/docs/*.md)
[ "${#files[@]}" -gt 0 ] || die "no files to scan"

rc=0
for i in "${!needles[@]}"; do
  if [ "$mode" = check ]; then
    if grep -nF -- "${needles[$i]}" "${files[@]}"; then rc=1; fi
  else
    # perl \Q..\E treats the needle literally; the dots in an IP are not wildcards
    NEEDLE=${needles[$i]} REPL=${repls[$i]} perl -pi -e 's/\Q$ENV{NEEDLE}\E/$ENV{REPL}/g' "${files[@]}"
  fi
done

# review list: informational only, you decide
grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}|@[A-Za-z0-9.-]+\.[a-z]{2,}' "${files[@]}" \
  | grep -vE '10\.42\.|0\.0\.0\.0|<admin-ip>|@sha256:' | sed 's/^/review: /' || true
[ "$rc" -eq 0 ] || die "known values still present"
log "$mode ok"
