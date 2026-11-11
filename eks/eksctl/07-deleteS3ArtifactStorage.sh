#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 07-deleteS3ArtifactStorage.sh — Teardown for 07-createS3ArtifactStorage.sh.
# DESTRUCTIVE: permanently deletes the bucket and ALL objects in it (build
# artifacts), plus the IAM policy, the artifacts role and its Pod Identity
# associations. Asks for confirmation (--yes skips it).
#
# Pod Identity associations that point to ANOTHER role (e.g. controller1/hahs on
# the backup role) are NOT deleted: only the artifacts policy is detached from
# that role, so its other access stays intact.
# -----------------------------------------------------------------------------
set -euo pipefail

source ./.env

log()     { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

ASSUME_YES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) ASSUME_YES=true ;;
    *)        error "unknown flag '$1' (supported: --yes)" ;;
  esac
  shift
done

AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

S3_ARTIFACTS_BUCKET="${S3_ARTIFACTS_BUCKET:-${CLUSTER_NAME}-cbci-artifacts-${AWS_ACCOUNT_ID}}"
S3_ARTIFACTS_POLICY_NAME="${S3_ARTIFACTS_POLICY_NAME:-CBCI-S3Artifacts-Policy-${CLUSTER_NAME}}"
S3_ARTIFACTS_ROLE_NAME="${S3_ARTIFACTS_ROLE_NAME:-CBCI-S3Artifacts-Role-${CLUSTER_NAME}}"
S3_ARTIFACTS_SA_NAMESPACE="${S3_ARTIFACTS_SA_NAMESPACE:-${NAMESPACE_CLOUDBEES}}"
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${S3_ARTIFACTS_POLICY_NAME}"

echo "This will permanently delete:"
echo "  - s3://${S3_ARTIFACTS_BUCKET} and all its contents"
echo "  - IAM policy ${S3_ARTIFACTS_POLICY_NAME} (detached from every role using it)"
echo "  - IAM role ${S3_ARTIFACTS_ROLE_NAME} and the pod identity associations that use it"
if [[ "${ASSUME_YES}" != true ]]; then
  read -r -p "Type the bucket name to confirm: " CONFIRM
  [[ "${CONFIRM}" == "${S3_ARTIFACTS_BUCKET}" ]] || error "Confirmation did not match; aborting."
fi

# --- Pod Identity associations that use the artifacts role -------------------
ROLE_ARN=$(aws iam get-role --role-name "${S3_ARTIFACTS_ROLE_NAME}" \
  --query Role.Arn --output text 2>/dev/null || true)
if [[ -n "${ROLE_ARN}" && "${ROLE_ARN}" != "None" ]]; then
  ASSOCS=$(aws eks list-pod-identity-associations --cluster-name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" --namespace "${S3_ARTIFACTS_SA_NAMESPACE}" \
    --query "associations[].associationId" --output text 2>/dev/null || true)
  for ASSOC in ${ASSOCS}; do
    ASSOC_ROLE_ARN=$(aws eks describe-pod-identity-association --cluster-name "${CLUSTER_NAME}" \
      --region "${AWS_REGION}" --association-id "${ASSOC}" \
      --query association.roleArn --output text)
    if [[ "${ASSOC_ROLE_ARN}" == "${ROLE_ARN}" ]]; then
      log "Deleting pod identity association ${ASSOC}..."
      aws eks delete-pod-identity-association --cluster-name "${CLUSTER_NAME}" \
        --region "${AWS_REGION}" --association-id "${ASSOC}" >/dev/null
    fi
  done
fi

# --- IAM policy: detach from every role (artifacts role + shared roles) ------
if aws iam get-policy --policy-arn "${POLICY_ARN}" >/dev/null 2>&1; then
  for ROLE in $(aws iam list-entities-for-policy --policy-arn "${POLICY_ARN}" \
      --query 'PolicyRoles[].RoleName' --output text); do
    log "Detaching ${S3_ARTIFACTS_POLICY_NAME} from role ${ROLE}..."
    aws iam detach-role-policy --role-name "${ROLE}" --policy-arn "${POLICY_ARN}"
  done
  # delete-policy fails while non-default versions exist.
  for VERSION in $(aws iam list-policy-versions --policy-arn "${POLICY_ARN}" \
      --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "${POLICY_ARN}" --version-id "${VERSION}"
  done
  log "Deleting IAM policy ${S3_ARTIFACTS_POLICY_NAME}..."
  aws iam delete-policy --policy-arn "${POLICY_ARN}"
fi

# --- IAM role ----------------------------------------------------------------
if aws iam get-role --role-name "${S3_ARTIFACTS_ROLE_NAME}" >/dev/null 2>&1; then
  # delete-role fails while any policy is attached. Other policies can sit here:
  # 07-createS3BackupBucket.sh attaches the backup policy to the role a
  # ServiceAccount already uses (a ServiceAccount has only one association).
  for ARN in $(aws iam list-attached-role-policies --role-name "${S3_ARTIFACTS_ROLE_NAME}" \
      --query 'AttachedPolicies[].PolicyArn' --output text); do
    log "Detaching ${ARN##*/} from role ${S3_ARTIFACTS_ROLE_NAME} (re-run its create script to restore that access)..."
    aws iam detach-role-policy --role-name "${S3_ARTIFACTS_ROLE_NAME}" --policy-arn "${ARN}"
  done
  log "Deleting IAM role ${S3_ARTIFACTS_ROLE_NAME}..."
  aws iam delete-role --role-name "${S3_ARTIFACTS_ROLE_NAME}"
fi

# --- Bucket ------------------------------------------------------------------
if aws s3api head-bucket --bucket "${S3_ARTIFACTS_BUCKET}" 2>/dev/null; then
  log "Emptying and deleting bucket ${S3_ARTIFACTS_BUCKET}..."
  aws s3 rm "s3://${S3_ARTIFACTS_BUCKET}" --recursive >/dev/null
  aws s3api delete-bucket --bucket "${S3_ARTIFACTS_BUCKET}" --region "${AWS_REGION}"
fi

success "Artifact storage resources removed."
