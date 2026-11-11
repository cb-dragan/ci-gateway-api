#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 01-deleteCluster.sh — Orchestrates the COMPLETE teardown of this environment
# by calling the existing delete scripts in reverse order of creation, then the
# EKS cluster itself, then a read-only scan for orphaned resources.
#
# ORDER (each step is auto-detected and skipped when nothing is found)
#   1. 07-deleteEC2WithController.sh --delete-cert   EC2 add-on, ALB listener rule
#   2. 05-deleteCloudBees.sh --delete-data --delete-namespace
#   3. 07-deleteS3PlugableStorage-LogsBucket.sh      DESTRUCTIVE (bucket + data)
#      07-deleteS3ArtifactStorage.sh                 DESTRUCTIVE (bucket + data)
#      07-deleteS3BackupBucket.sh                    DESTRUCTIVE (bucket + data)
#   4. 04-deleteNginx.sh                             ingress-nginx, NLB (before Envoy: both use the ACM cert)
#   5. 04-deleteEnvoy.sh --delete-crds --delete-cert Ingress -> ALB, Envoy, ACM cert + its Route53 validation record
#   6. 06-deleteExternalDNS.sh                       Route53 records, IAM role/policy
#   7. 02-delete-efs-filesystem.sh --yes             EFS, mount targets, SG
#   8. eksctl delete cluster                         cluster, VPC, node groups, eksctl IAM,
#                                                    then local cleanup (kubeconfig entry, node pool state files)
#   9. Orphan report (read-only): anything still tagged for / named after the cluster,
#      EKS OIDC providers without a cluster, unattached EBS CSI volumes
#
# 03-* (LB controller, Cluster Autoscaler) and 08-* (remote-agent ServiceAccount)
# have no delete script; they live inside the cluster and go with it.
#
# SAFETY
#   Prints the plan first and requires typing the cluster name. A step that
#   fails aborts the run; every child script is idempotent, so fix the cause and
#   re-run. Nothing is deleted before the plan is confirmed.
#
# Usage:
#   ./01-deleteCluster.sh                # plan, typed confirmation, delete
#   ./01-deleteCluster.sh --dry-run      # print the plan only
#   ./01-deleteCluster.sh --yes          # skip the typed confirmation (CI/automation)
#   ./01-deleteCluster.sh --report-only  # only run the orphan report
# -----------------------------------------------------------------------------
set -euo pipefail

source ./.env

log()     { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

ASSUME_YES=false
DRY_RUN=false
REPORT_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)       ASSUME_YES=true ;;
    --dry-run)      DRY_RUN=true ;;
    --report-only)  REPORT_ONLY=true ;;
    -h|--help)      awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *)              error "unknown flag '$1' (try --help)" ;;
  esac
  shift
done

for bin in aws eksctl kubectl helm jq envsubst; do
  command -v "$bin" >/dev/null 2>&1 || error "required tool '$bin' not found on PATH"
done

AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) \
  || error "AWS credentials not valid. Run 00-login.sh first."

# Names must match the create scripts' defaults.
EFS_NAME="${EFS_NAME:-${CLUSTER_NAME}-efs}"
EC2_HOST_NAME="${EC2_CONTROLLER_HOST_NAME:-ec2-controller.acaternberg.aws.ps.beescloud.com}"
EC2_INSTANCE_NAME="${EC2_CONTROLLER_INSTANCE_NAME:-${CLUSTER_NAME}-ec2-controller}"
S3_BACKUP_BUCKET="${S3_BACKUP_BUCKET:-${CLUSTER_NAME}-cbci-backup-${AWS_ACCOUNT_ID}}"
S3_ARTIFACTS_BUCKET="${S3_ARTIFACTS_BUCKET:-${CLUSTER_NAME}-cbci-artifacts-${AWS_ACCOUNT_ID}}"
S3_LOGS_BUCKET="${S3_LOGS_BUCKET:-${CLUSTER_NAME}-cbci-logs-${AWS_ACCOUNT_ID}}"
EXTERNAL_DNS_ROLE_NAME="${EXTERNAL_DNS_ROLE_NAME:-AmazonEKS_ExternalDNS_Role-${CLUSTER_NAME}}"
EXTERNAL_DNS_POLICY_NAME="${EXTERNAL_DNS_POLICY_NAME:-AmazonEKS_ExternalDNS_Policy-${CLUSTER_NAME}}"
NAMESPACE_EXTERNAL_DNS="${NAMESPACE_EXTERNAL_DNS:-external-dns}"
CLOUDBEES_RELEASE_NAME="${CLOUDBEES_RELEASE_NAME:-cloudbees-core-envoy}"
INGRESS_NGINX_NAMESPACE="${INGRESS_NGINX_NAMESPACE:-ingress-nginx}"

# =============================================================================
# DETECTION (read-only). Each has_* returns 0 if there is something to delete.
# =============================================================================
CLUSTER_EXISTS=false
aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" &>/dev/null && CLUSTER_EXISTS=true

K8S_OK=false
if [[ "$CLUSTER_EXISTS" == true ]] && kubectl get namespace kube-system --request-timeout=15s &>/dev/null; then
  K8S_OK=true
fi

has_ec2() {
  local n
  n=$(aws ec2 describe-instances --region "$AWS_REGION" \
        --filters "Name=tag:Name,Values=${EC2_INSTANCE_NAME}" \
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'length(Reservations[].Instances[])' --output text 2>/dev/null || echo 0)
  [[ "$n" != "0" && "$n" != "None" ]] && return 0
  aws iam get-role --role-name "${EC2_INSTANCE_NAME}-role" &>/dev/null
}
has_cloudbees() {
  [[ "$K8S_OK" == true ]] && kubectl get namespace "$NAMESPACE_CLOUDBEES" &>/dev/null
}
has_s3() { aws s3api head-bucket --bucket "$1" &>/dev/null; }
has_s3_logs()      { has_s3 "$S3_LOGS_BUCKET"; }
has_s3_artifacts() { has_s3 "$S3_ARTIFACTS_BUCKET"; }
has_s3_backup()    { has_s3 "$S3_BACKUP_BUCKET"; }
has_envoy() {
  [[ "$K8S_OK" == true ]] || return 1
  helm status eg -n "$ENVOY_GW_NAMESPACE" &>/dev/null \
    || kubectl get namespace "$ENVOY_GW_NAMESPACE" &>/dev/null \
    || kubectl get gateway "$GATEWAY_NAME" -n "$NAMESPACE_CLOUDBEES" &>/dev/null
}
has_nginx() {
  [[ "$K8S_OK" == true ]] || return 1
  helm status ingress-nginx -n "$INGRESS_NGINX_NAMESPACE" &>/dev/null \
    || kubectl get namespace "$INGRESS_NGINX_NAMESPACE" &>/dev/null
}
# The ACM cert is shared by the nginx NLB and the Envoy ALB: the last of the two
# to be removed deletes it, so the nginx step only does it when there is no Envoy.
NGINX_CERT_FLAG="--delete-cert"
has_envoy && NGINX_CERT_FLAG=""
has_acm_cert() {
  local n
  n=$(aws acm list-certificates --region "$AWS_REGION" \
        --query "length(CertificateSummaryList[?DomainName=='$1'])" --output text 2>/dev/null || echo 0)
  [[ "$n" != "0" && "$n" != "None" ]]
}
has_external_dns() {
  { [[ "$K8S_OK" == true ]] && helm status external-dns -n "$NAMESPACE_EXTERNAL_DNS" &>/dev/null; } \
    || aws iam get-role --role-name "$EXTERNAL_DNS_ROLE_NAME" &>/dev/null \
    || aws iam get-policy \
         --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${EXTERNAL_DNS_POLICY_NAME}" &>/dev/null
}
has_efs() {
  local id
  id=$(aws efs describe-file-systems --region "$AWS_REGION" \
        --query "FileSystems[?Tags[?Key=='Name' && Value=='${EFS_NAME}']].FileSystemId | [0]" \
        --output text 2>/dev/null || true)
  [[ -n "$id" && "$id" != "None" ]]
}
has_cluster() { [[ "$CLUSTER_EXISTS" == true ]]; }

# =============================================================================
# LOCAL CLEANUP (after the cluster is gone)
# =============================================================================
cleanup_local() {
  local arn="arn:aws:eks:${AWS_REGION}:${AWS_ACCOUNT_ID}:cluster/${CLUSTER_NAME}" contexts
  # eksctl removes its own kubeconfig entries; `aws eks update-kubeconfig`
  # (01-createCluster.sh) adds ones named after the cluster ARN.
  contexts=$(kubectl config get-contexts -o name 2>/dev/null || true)
  if [[ $'\n'"${contexts}"$'\n' == *$'\n'"${arn}"$'\n'* ]]; then
    kubectl config delete-context "$arn" >/dev/null 2>&1 || true
    kubectl config delete-cluster "$arn" >/dev/null 2>&1 || true
    kubectl config delete-user "$arn" >/dev/null 2>&1 || true
    success "Removed the kubeconfig entries for ${arn}."
  fi
  # Sizes saved for this cluster: 01-scaleUpNodePools.sh would apply them to the next one.
  local state="${NODEPOOL_STATE_FILE:-.nodepool-scale-state.json}"
  rm -f "$state" "${state}.bak" "${state}.autoscaler"
}

# =============================================================================
# ORPHAN REPORT (read-only; never deletes)
# =============================================================================
orphan_report() {
  local found=0 out
  report() { warn "STILL EXISTS: $*"; found=$((found + 1)); }

  log "Scanning for resources that outlived the teardown (read-only)..."

  aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" &>/dev/null \
    && report "EKS cluster ${CLUSTER_NAME}"

  out=$(aws cloudformation list-stacks --region "$AWS_REGION" \
    --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
      ROLLBACK_COMPLETE CREATE_FAILED DELETE_FAILED DELETE_IN_PROGRESS \
    --query "StackSummaries[?starts_with(StackName,'eksctl-${CLUSTER_NAME}-')].[StackName,StackStatus]" \
    --output text 2>/dev/null || true)
  while IFS=$'\t' read -r name status; do
    [[ -n "${name:-}" ]] && report "CloudFormation stack ${name} (${status})"
  done <<< "$out"

  # Anything carrying the cluster's ownership tags: ALBs, ENIs, SGs, EBS volumes, ...
  local arns=""
  arns+=$(aws resourcegroupstaggingapi get-resources --region "$AWS_REGION" \
    --tag-filters "Key=kubernetes.io/cluster/${CLUSTER_NAME}" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null | tr '\t' '\n' || true)
  arns+=$'\n'
  arns+=$(aws resourcegroupstaggingapi get-resources --region "$AWS_REGION" \
    --tag-filters "Key=elbv2.k8s.aws/cluster,Values=${CLUSTER_NAME}" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null | tr '\t' '\n' || true)
  arns+=$'\n'
  arns+=$(aws resourcegroupstaggingapi get-resources --region "$AWS_REGION" \
    --tag-filters "Key=alpha.eksctl.io/cluster-name,Values=${CLUSTER_NAME}" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null | tr '\t' '\n' || true)
  while read -r arn; do
    [[ -n "$arn" && "$arn" != "None" ]] && report "tagged resource ${arn}"
  done < <(printf '%s\n' "$arns" | sort -u)

  # IAM OIDC providers (IRSA) of EKS clusters in this region that no cluster uses any more.
  local live_ids="" c oidc_arn oidc_id vol size pvc_ns
  for c in $(aws eks list-clusters --region "$AWS_REGION" --query 'clusters[]' --output text 2>/dev/null || true); do
    live_ids+=$(aws eks describe-cluster --name "$c" --region "$AWS_REGION" \
      --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null | sed 's#.*/id/##' || true)
    live_ids+=$'\n'
  done
  for oidc_arn in $(aws iam list-open-id-connect-providers \
      --query 'OpenIDConnectProviderList[].Arn' --output text 2>/dev/null || true); do
    [[ "$oidc_arn" == *"oidc.eks.${AWS_REGION}.amazonaws.com/id/"* ]] || continue
    oidc_id="${oidc_arn##*/}"
    [[ $'\n'"${live_ids}" == *$'\n'"${oidc_id}"$'\n'* ]] \
      || report "IAM OIDC provider ${oidc_arn} (no EKS cluster uses it)"
  done

  # Unattached EBS volumes made by the EBS CSI driver. The tag is not cluster
  # specific, so a volume listed here may belong to another cluster.
  out=$(aws ec2 describe-volumes --region "$AWS_REGION" \
    --filters "Name=status,Values=available" "Name=tag-key,Values=ebs.csi.aws.com/cluster" \
    --query 'Volumes[].[VolumeId,Size,Tags[?Key==`kubernetes.io/created-for/pvc/namespace`]|[0].Value]' \
    --output text 2>/dev/null || true)
  while IFS=$'\t' read -r vol size pvc_ns; do
    [[ -n "${vol:-}" ]] && report "unattached EBS CSI volume ${vol} (${size} GiB, PVC namespace ${pvc_ns:-?}); may belong to another cluster"
  done <<< "$out"

  # Named resources created by the add-on scripts.
  for b in "$S3_BACKUP_BUCKET" "$S3_ARTIFACTS_BUCKET" "$S3_LOGS_BUCKET"; do
    has_s3 "$b" && report "S3 bucket ${b}"
  done
  has_efs && report "EFS file system ${EFS_NAME}"
  has_ec2 && report "EC2 controller add-on (${EC2_INSTANCE_NAME})"

  local roles=("$EXTERNAL_DNS_ROLE_NAME" "${EC2_INSTANCE_NAME}-role"
    "${S3_BACKUP_ROLE_NAME:-CBCI-S3Backup-Role-${CLUSTER_NAME}}"
    "${S3_ARTIFACTS_ROLE_NAME:-CBCI-S3Artifacts-Role-${CLUSTER_NAME}}"
    "${S3_LOGS_ROLE_NAME:-CBCI-S3Logs-Role-${CLUSTER_NAME}}"
    "${EFS_CSI_ROLE_NAME:-AmazonEKS_EFS_CSI_DriverRole-${CLUSTER_NAME}}")
  for r in "${roles[@]}"; do
    aws iam get-role --role-name "$r" &>/dev/null && report "IAM role ${r}"
  done
  local policies=("$EXTERNAL_DNS_POLICY_NAME"
    "${S3_BACKUP_POLICY_NAME:-CBCI-S3Backup-Policy-${CLUSTER_NAME}}"
    "${S3_ARTIFACTS_POLICY_NAME:-CBCI-S3Artifacts-Policy-${CLUSTER_NAME}}"
    "${S3_LOGS_POLICY_NAME:-CBCI-S3Logs-Policy-${CLUSTER_NAME}}")
  for p in "${policies[@]}"; do
    aws iam get-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${p}" &>/dev/null \
      && report "IAM policy ${p}"
  done

  for h in "$CJOC_HOST_NAME" "$EC2_HOST_NAME"; do
    has_acm_cert "$h" && report "ACM certificate for ${h}"
  done

  # Route53: host records, external-dns TXT records and ACM validation CNAMEs.
  for h in "$CJOC_HOST_NAME" "$EC2_HOST_NAME"; do
    local zone_domain zone_id
    zone_domain=$(cut -d. -f2- <<< "$h")
    zone_id=$(aws route53 list-hosted-zones-by-name --dns-name "$zone_domain" \
      --query "HostedZones[?Name=='${zone_domain}.' && Config.PrivateZone==\`false\`].Id | [0]" \
      --output text 2>/dev/null | sed 's|/hostedzone/||' || true)
    [[ -z "$zone_id" || "$zone_id" == "None" ]] && continue
    out=$(aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" --output json \
      | jq -r --arg h "${h}." '.ResourceRecordSets[]
          | select(.Name == $h or .Name == ("a-" + $h) or .Name == ("cname-" + $h)
                   or (.Name | endswith("." + $h)))
          | select(.Type != "NS" and .Type != "SOA") | "\(.Type) \(.Name)"' 2>/dev/null || true)
    while read -r rec; do
      [[ -n "$rec" ]] && report "Route53 record ${rec}"
    done <<< "$out"
  done

  if (( found == 0 )); then
    success "No leftover resources found."
  else
    warn "${found} item(s) remain. Review them (they may still bill) and remove manually or re-run the matching delete script."
  fi
}

if [[ "$REPORT_ONLY" == true ]]; then
  orphan_report
  exit 0
fi

# =============================================================================
# PLAN
# =============================================================================
STEP_LABEL=(); STEP_FN=(); STEP_CMD=(); STEP_RUN=()
add_step() { STEP_LABEL+=("$1"); STEP_FN+=("$2"); STEP_CMD+=("$3"); }

add_step "EC2 Client Controller add-on (+ ACM cert)"      has_ec2           "./07-deleteEC2WithController.sh --delete-cert --yes"
add_step "CloudBees CI, PVCs/JENKINS_HOME and namespaces" has_cloudbees     "./05-deleteCloudBees.sh --delete-data --delete-namespace --yes"
add_step "S3 build-logs bucket (DESTRUCTIVE)"             has_s3_logs       "./07-deleteS3PlugableStorage-LogsBucket.sh --yes"
add_step "S3 artifacts bucket (DESTRUCTIVE)"              has_s3_artifacts  "./07-deleteS3ArtifactStorage.sh --yes"
add_step "S3 backup bucket (DESTRUCTIVE)"                 has_s3_backup     "./07-deleteS3BackupBucket.sh --yes"
add_step "ingress-nginx and its NLB"                      has_nginx         "./04-deleteNginx.sh ${NGINX_CERT_FLAG} --yes"
add_step "Envoy Gateway, ALB, CRDs and ACM cert"          has_envoy         "./04-deleteEnvoy.sh --delete-crds --delete-cert --yes"
add_step "external-dns, Route53 records, IAM role/policy" has_external_dns  "./06-deleteExternalDNS.sh --yes"
add_step "EFS file system, mount targets, SG"             has_efs           "./02-delete-efs-filesystem.sh --yes"
add_step "EKS cluster ${CLUSTER_NAME} (eksctl)"           has_cluster       "eksctl"

echo
warn "TEARDOWN PLAN for cluster '${CLUSTER_NAME}' (account ${AWS_ACCOUNT_ID}, ${AWS_REGION})"
[[ "$CLUSTER_EXISTS" != true ]] && warn "Cluster not found: Kubernetes-side steps are skipped, AWS-side leftovers are still cleaned."
[[ "$CLUSTER_EXISTS" == true && "$K8S_OK" != true ]] && warn "Cluster exists but kubectl cannot reach it (KUBECONFIG=${KUBECONFIG:-unset}); Kubernetes-side steps are skipped. Fix access first, or ALBs/ENIs may be orphaned."
i=0
for label in "${STEP_LABEL[@]}"; do
  if "${STEP_FN[$i]}"; then STEP_RUN+=(1); printf '  \033[1;31m[DELETE]\033[0m %s\n' "$label"
  else                      STEP_RUN+=(0); printf '  [skip]   %s (nothing found)\n' "$label"; fi
  i=$((i + 1))
done
echo
echo "  IRREVERSIBLE: deleted data includes JENKINS_HOME volumes and the S3 buckets listed above."
echo

if [[ "$DRY_RUN" == true ]]; then
  log "Dry run: nothing deleted."
  exit 0
fi

if [[ "$ASSUME_YES" != true ]]; then
  read -r -p "Type the cluster name (${CLUSTER_NAME}) to confirm: " CONFIRM
  [[ "$CONFIRM" == "$CLUSTER_NAME" ]] || error "Confirmation did not match; aborting."
fi

# =============================================================================
# EXECUTE
# =============================================================================
trap 'echo; warn "Teardown stopped at step: ${CURRENT_STEP:-?}. Fix the cause and re-run; completed steps are skipped automatically."' ERR

i=0
for label in "${STEP_LABEL[@]}"; do
  if [[ "${STEP_RUN[$i]}" == 1 ]]; then
    CURRENT_STEP="$label"
    echo
    log "=== ${label} ==="
    if [[ "${STEP_CMD[$i]}" == "eksctl" ]]; then
      envsubst < eksctl-config.yaml.tpl > eksctl-config.yaml
      log "Deleting EKS cluster ${CLUSTER_NAME} in region ${AWS_REGION}..."
      eksctl delete cluster -f eksctl-config.yaml --wait --force --disable-nodegroup-eviction
      cleanup_local
    else
      # shellcheck disable=SC2086
      bash ${STEP_CMD[$i]}
    fi
    success "${label}: done."
  fi
  i=$((i + 1))
done
trap - ERR

echo
orphan_report
