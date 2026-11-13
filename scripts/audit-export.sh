#!/usr/bin/env bash
# exports event history for the CI role to our audit bucket and queries it with athena
set -euo pipefail; set -C

VERSION=0.1.0
REGION=eu-central-1
ROLE_NAME=rg-vaultly-gha-readonly
DB=rg_vaultly
HOURS=48
QID=

usage() {
  cat <<EOF
Usage: audit-export.sh [--hours N] [--help|--version]

Exports CloudTrail event history (last N hours, default 48) that mentions
${ROLE_NAME} to s3://rg-vaultly-audit-<account>-${REGION}/exports/events.json,
creates the athena table ${DB}.audit_events if missing and runs one query.
EOF
}
die() { echo "audit-export.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case $1 in
    --help) usage; exit 0 ;;
    --version) echo "audit-export.sh $VERSION"; exit 0 ;;
    --hours) [ $# -ge 2 ] || die "--hours needs a value"; HOURS=$2; shift 2 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
case $HOURS in '' | *[!0-9]*) die "--hours must be a number" ;; esac

export AWS_DEFAULT_REGION=$REGION
acct=$(aws sts get-caller-identity --query Account --output text)
bucket="rg-vaultly-audit-${acct}-${REGION}"
aws s3api head-bucket --bucket "$bucket" || die "bucket missing: apply infra/audit-trail first"

run_query() {
  local sql=$1 db=${2:-} id state i
  local args=(--query-string "$sql"
    --result-configuration "OutputLocation=s3://${bucket}/athena-results/"
    --query QueryExecutionId --output text)
  if [ -n "$db" ]; then args+=(--query-execution-context "Database=$db"); fi
  id=$(aws athena start-query-execution "${args[@]}")
  for ((i = 0; i < 60; i++)); do
    state=$(aws athena get-query-execution --query-execution-id "$id" \
      --query QueryExecution.Status.State --output text)
    case $state in
      SUCCEEDED) QID=$id; return 0 ;;
      FAILED | CANCELLED) die "athena query $state (id $id)" ;;
    esac
    sleep 2
  done
  die "athena query timed out (id $id)"
}

tmp=$(mktemp "${TMPDIR:-/tmp}/audit-export.XXXXXX")
trap 'rm -f "$tmp"' EXIT
start=$(date -u -d "-${HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)
# lookup-events takes one attribute per call and is limited to 2 requests per second
for name in AssumeRoleWithWebIdentity GetParameter; do
  aws cloudtrail lookup-events --start-time "$start" \
    --lookup-attributes "AttributeKey=EventName,AttributeValue=${name}" --output json \
    | jq -c --arg role "$ROLE_NAME" \
      '.Events[].CloudTrailEvent | fromjson | select(tostring | contains($role))' >> "$tmp"
  sleep 1
done
n=$(wc -l < "$tmp")
[ "$n" -gt 0 ] || die "no events mention ${ROLE_NAME} in ${HOURS}h (history lags a few minutes)"
echo "events exported: $n"
aws s3 cp "$tmp" "s3://${bucket}/exports/events.json" --only-show-errors

run_query "CREATE DATABASE IF NOT EXISTS ${DB}"
run_query "CREATE EXTERNAL TABLE IF NOT EXISTS ${DB}.audit_events (eventtime string, eventname string, eventsource string, awsregion string, errorcode string) ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe' WITH SERDEPROPERTIES ('ignore.malformed.json'='true') LOCATION 's3://${bucket}/exports/'"
run_query "SELECT eventname, coalesce(errorcode, 'Success') AS outcome, count(*) AS events, min(eventtime) AS first_seen FROM audit_events GROUP BY 1, 2 ORDER BY 1, 2" "$DB"
aws athena get-query-results --query-execution-id "$QID" --output json \
  | jq -r '.ResultSet.Rows[] | [.Data[].VarCharValue] | @tsv'
