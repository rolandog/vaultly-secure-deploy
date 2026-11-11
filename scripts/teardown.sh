#!/usr/bin/env bash
# teardown.sh: remove OpenBao data and SSM secrets, destroy platform, eks, network, verify leftovers
set -euo pipefail; set -C

PROG=${0##*/}
VERSION=0.1.1
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

CLUSTER=${CLUSTER_NAME:-rg-vaultly}
SSM_PREFIX=${SSM_PREFIX:-/rg-vaultly/openbao/}

usage() {
  cat <<EOF2
Usage: $PROG [--help|--version] [all|k8s|ssm|tofu|verify]

k8s     delete namespace vaultly, uninstall OpenBao, delete its PVCs, wait for the EBS volumes
ssm     delete SSM parameters under $SSM_PREFIX (recovery keys and root token: rebuild needs init)
tofu    destroy the roots platform, eks, network in that order (each asks for confirmation)
verify  scoped leftover checks (tag Namespace=rg, name prefix); exits 1 if anything is left
all     k8s, ssm, tofu, verify (default)
Destructive phases ask you to type the cluster name ($CLUSTER). Env: CLUSTER_NAME, SSM_PREFIX.
Output masks every 12-digit number (account ids).
EOF2
}

confirm() {
  local ans
  read -rp "this deletes data and infrastructure of $CLUSTER; type '$CLUSTER' to continue: " ans
  [ "$ans" = "$CLUSTER" ] || die "aborted"
}

# fail closed: an unreachable API must not read as "no pods"
no_pods() {
  local out
  out=$(kubectl -n openbao get pods -o name) || return 1
  [ -z "$out" ]
}

volumes_gone() {
  local v out
  for v in "$@"; do
    out=$(aws ec2 describe-volumes --filters "Name=volume-id,Values=$v" \
      --query 'Volumes[].VolumeId' --output text)
    [ -z "$out" ] || return 1
  done
}

k8s_phase() {
  if ! aws eks describe-cluster --name "$CLUSTER" >/dev/null 2>&1; then
    log "cluster $CLUSTER not found, skipping k8s phase"
    return 0
  fi
  [ "$(kubectl config current-context)" = "$CLUSTER" ] || die "kube context is not $CLUSTER"
  kubectl get nodes >/dev/null || die "cluster unreachable (try scripts/update-admin-ip.sh)"

  # remember the volume ids first: the PV objects vanish with the PVCs
  local vols
  vols=$(kubectl get pv -o jsonpath='{range .items[?(@.spec.claimRef.namespace=="openbao")]}{.spec.csi.volumeHandle}{"\n"}{end}')
  log "volumes to wait for: ${vols:-none}"

  kubectl delete namespace vaultly --ignore-not-found --timeout=120s
  if helm status openbao -n openbao >/dev/null 2>&1; then
    helm uninstall openbao -n openbao
  fi
  # PVCs are protected while a pod uses them, so wait for the pods first
  retry 30 5 no_pods || die "openbao pods still present"
  kubectl -n openbao delete pvc --all --ignore-not-found --timeout=180s

  if [ -n "$vols" ]; then
    local -a ids
    mapfile -t ids <<<"$vols"
    retry 36 5 volumes_gone "${ids[@]}" || die "EBS volumes still exist: $vols"
  fi
  log "k8s phase done"
}

ssm_phase() {
  local names
  names=$(aws ssm describe-parameters \
    --parameter-filters "Key=Name,Option=BeginsWith,Values=$SSM_PREFIX" \
    --query 'Parameters[].Name' --output text)
  if [ -z "$names" ]; then
    log "no parameters under $SSM_PREFIX"
    return 0
  fi
  local -a arr
  read -ra arr <<<"$names"
  aws ssm delete-parameters --names "${arr[@]}" >/dev/null
  log "deleted: ${arr[*]}"
}

tofu_phase() {
  local r
  for r in platform eks network; do
    log "destroy $r"
    "$ROOT/scripts/tf.sh" "$r" destroy
  done
}

bad=0
mask() { sed -E 's/[0-9]{12}/<acct>/g'; }

check() {
  local label=$1 out
  shift
  out=$("$@") || die "query failed: $label"
  if [ -z "$out" ] || [ "$out" = None ]; then
    printf 'ok    %s\n' "$label"
  else
    printf 'LEFT  %s: %s\n' "$label" "$out" | mask
    bad=1
  fi
}

verify_phase() {
  check "eks cluster" aws eks list-clusters --query "clusters[?starts_with(@,'$CLUSTER')]" --output text
  check "vpc (tag)" aws ec2 describe-vpcs --filters Name=tag:Namespace,Values=rg \
    --query 'Vpcs[].VpcId' --output text
  check "instances (tag)" aws ec2 describe-instances \
    --filters Name=tag:Namespace,Values=rg Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[].InstanceId' --output text
  # node instances do not carry Namespace=rg, so check the EKS tag too
  check "instances (eks:cluster-name)" aws ec2 describe-instances \
    --filters "Name=tag:eks:cluster-name,Values=$CLUSTER" Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[].InstanceId' --output text
  check "nat gateways" aws ec2 describe-nat-gateways \
    --filter Name=tag:Namespace,Values=rg Name=state,Values=pending,available,deleting \
    --query 'NatGateways[].NatGatewayId' --output text
  check "elastic ips" aws ec2 describe-addresses --filters Name=tag:Namespace,Values=rg \
    --query 'Addresses[].AllocationId' --output text
  check "internet gateways" aws ec2 describe-internet-gateways --filters Name=tag:Namespace,Values=rg \
    --query 'InternetGateways[].InternetGatewayId' --output text
  check "security groups" aws ec2 describe-security-groups --filters Name=tag:Namespace,Values=rg \
    --query 'SecurityGroups[].GroupId' --output text
  check "flow logs" aws ec2 describe-flow-logs --filter Name=tag:Namespace,Values=rg \
    --query 'FlowLogs[].FlowLogId' --output text
  check "launch templates" aws ec2 describe-launch-templates --filters Name=tag:Namespace,Values=rg \
    --query 'LaunchTemplates[].LaunchTemplateName' --output text
  check "ebs volumes" aws ec2 describe-volumes --filters Name=tag:Namespace,Values=rg \
    --query 'Volumes[].VolumeId' --output text
  check "db subnet group" aws rds describe-db-subnet-groups \
    --query "DBSubnetGroups[?DBSubnetGroupName=='$CLUSTER'].DBSubnetGroupName" --output text
  check "kms alias" aws kms list-aliases \
    --query "Aliases[?contains(AliasName,'vaultly')].AliasName" --output text
  check "eks log group" aws logs describe-log-groups --log-group-name-prefix "/aws/eks/$CLUSTER" \
    --query 'logGroups[].logGroupName' --output text
  check "iam roles" aws iam list-roles \
    --query "Roles[?starts_with(RoleName,'$CLUSTER')].RoleName" --output text
  check "ssm parameters" aws ssm describe-parameters \
    --parameter-filters 'Key=Name,Option=BeginsWith,Values=/rg-vaultly/' \
    --query 'Parameters[].Name' --output text

  # the tagging API also returns deleted resources for hours, so this is informational only
  local sweep arn
  sweep=$(aws resourcegroupstaggingapi get-resources --tag-filters Key=Namespace,Values=rg \
    --query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n' | mask)
  echo "## kms keys tagged Namespace=rg: expect PendingDeletion for ours (state, deletion date, description)"
  while read -r arn; do
    [ -n "$arn" ] || continue
    printf '%s  ' "${arn##*/}"
    aws kms describe-key --key-id "${arn##*/}" \
      --query 'KeyMetadata.[KeyState,DeletionDate,Description]' --output text
  done < <(grep -F ':key/' <<<"$sweep" || true)
  echo "## other tagged arns (informational; may include deleted ghosts and other labs, e.g. rg-p2-*)"
  grep -vF ':key/' <<<"$sweep" || true

  [ "$bad" -eq 0 ] || die "leftovers found"
  log "verify ok"
}

case "${1:-all}" in
  -h|--help) usage; exit 0 ;;
  -V|--version) print_version; exit 0 ;;
  all)    need aws; need kubectl; need helm; confirm; k8s_phase; ssm_phase; tofu_phase; verify_phase ;;
  k8s)    need aws; need kubectl; need helm; confirm; k8s_phase ;;
  ssm)    need aws; confirm; ssm_phase ;;
  tofu)   need aws; confirm; tofu_phase ;;
  verify) need aws; verify_phase ;;
  *)      usage >&2; exit 2 ;;
esac
