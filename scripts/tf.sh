#!/usr/bin/env bash
# tf.sh: run tofu in one infra root against the shared S3 state bucket
set -euo pipefail; set -C

PROG=${0##*/}
VERSION=0.1.0
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

usage() {
  cat <<EOF
Usage: $PROG [--help|--version] ROOT COMMAND [tofu args...]

ROOT is a directory under infra/ (network, eks, platform, ...).
COMMAND is one of: init validate fmt plan apply destroy output state

The backend bucket is tf-state-<account>-eu-central-1 and is never created
or deleted here (see scripts/bootstrap-state.sh). Needs OpenTofu 1.10+.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  -V|--version) print_version; exit 0 ;;
esac
[ $# -ge 2 ] || { usage >&2; exit 2; }

root=$1 cmd=$2
shift 2
case "$root" in modules|bootstrap) die "not a root module: $root" ;; esac
dir=$ROOT/infra/$root
[ -d "$dir" ] || die "no such root: infra/$root"
# a root without a backend block would silently keep state in a local file
grep -qs 'backend "s3"' "$dir"/*.tf || die "infra/$root has no backend \"s3\" block (state would be local)"
need tofu; need aws

# one provider download for all roots (the disk is small)
export TF_PLUGIN_CACHE_DIR=${TF_PLUGIN_CACHE_DIR:-$HOME/.cache/tofu}
mkdir -p "$TF_PLUGIN_CACHE_DIR"

acct=$(aws sts get-caller-identity --query Account --output text)
bucket=tf-state-${acct}-eu-central-1

case "$cmd" in
  init)
    aws s3api head-bucket --bucket "$bucket" || die "state bucket missing: run scripts/bootstrap-state.sh"
    tofu -chdir="$dir" init -backend-config="bucket=$bucket" "$@" ;;
  validate|fmt|plan|apply|destroy|output|state)
    tofu -chdir="$dir" "$cmd" "$@" ;;
  *) die "unknown command: $cmd" ;;
esac
