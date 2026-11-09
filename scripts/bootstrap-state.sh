#!/usr/bin/env bash
# bootstrap-state.sh: create the shared state bucket only if missing, then verify it
set -euo pipefail; set -C

PROG=${0##*/}
VERSION=0.1.0
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

case "${1:-}" in
  -h|--help) echo "Usage: $PROG [--help|--version]"; echo "Creates tf-state-<account>-eu-central-1 if missing; otherwise verifies it read-only."; exit 0 ;;
  -V|--version) print_version; exit 0 ;;
esac
need aws; need jq

region=eu-central-1
acct=$(aws sts get-caller-identity --query Account --output text)
bucket=tf-state-${acct}-${region}

if aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
  log "bucket exists, verifying only: $bucket"
else
  log "creating $bucket"
  aws s3api create-bucket --bucket "$bucket" --region "$region" \
    --create-bucket-configuration "LocationConstraint=$region" >/dev/null
  aws s3api put-bucket-versioning --bucket "$bucket" \
    --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "$bucket" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-public-access-block --bucket "$bucket" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
fi

v=$(aws s3api get-bucket-versioning --bucket "$bucket" --query Status --output text)
e=$(aws s3api get-bucket-encryption --bucket "$bucket" \
  --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text)
aws s3api get-public-access-block --bucket "$bucket" \
  --query PublicAccessBlockConfiguration | jq -e 'all(.[]; . == true)' >/dev/null \
  || die "public access is not fully blocked on $bucket"
[ "$v" = Enabled ] || die "versioning is $v on $bucket"
log "ok: $bucket versioning=$v encryption=$e public-access=blocked"
