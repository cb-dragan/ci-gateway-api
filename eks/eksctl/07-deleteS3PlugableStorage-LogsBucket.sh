#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 07-deleteS3PlugableStorage-LogsBucket.sh — Teardown for
# 07-createS3PlugableStorage-LogsBucket.sh.
# DESTRUCTIVE: permanently deletes the bucket and ALL objects in it (build logs),
# plus the IAM policy, role and Pod Identity association. Asks for confirmation (--yes skips it).
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

S3_LOGS_BUCKET="${S3_LOGS_BUCKET:-${CLUSTER_NAME}-cbci-logs-${AWS_ACCOUNT_ID}}"
S3_LOGS_POLICY_NAME="${S3_LOGS_POLICY_NAME:-CBCI-S3Logs-Policy-${CLUSTER_NAME}}"
S3_LOGS_ROLE_NAME="${S3_LOGS_ROLE_NAME:-CBCI-S3Logs-Role-${CLUSTER_NAME}}"
S3_LOGS_SA_NAME="${S3_LOGS_SA_NAME:-pluggable-storage-service}"
S3_LOGS_SA_NAMESPACE="${S3_LOGS_SA_NAMESPACE:-${NAMESPACE_CLOUDBEES}}"
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${S3_LOGS_POLICY_NAME}"

echo "This will permanently delete:"
echo "  - s3://${S3_LOGS_BUCKET} and all its contents"
echo "  - IAM policy ${S3_LOGS_POLICY_NAME}, role ${S3_LOGS_ROLE_NAME}"
echo "  - Pod identity association ${S3_LOGS_SA_NAMESPACE}/${S3_LOGS_SA_NAME}"
if [[ "${ASSUME_YES}" != true ]]; then
  read -r -p "Type the bucket name to confirm: " CONFIRM
  [[ "${CONFIRM}" == "${S3_LOGS_BUCKET}" ]] || error "Confirmation did not match; aborting."
fi

# --- Pod Identity association ---
ASSOC=$(aws eks list-pod-identity-associations --cluster-name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" --namespace "${S3_LOGS_SA_NAMESPACE}" \
  --query "associations[?serviceAccount=='${S3_LOGS_SA_NAME}'].associationId | [0]" \
  --output text 2>/dev/null || true)
if [[ -n "${ASSOC}" && "${ASSOC}" != "None" ]]; then
  log "Deleting pod identity association ${ASSOC}..."
  aws eks delete-pod-identity-association --cluster-name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" --association-id "${ASSOC}" >/dev/null
fi

# --- IAM role + policy ---
if aws iam get-role --role-name "${S3_LOGS_ROLE_NAME}" >/dev/null 2>&1; then
  log "Deleting IAM role ${S3_LOGS_ROLE_NAME}..."
  aws iam detach-role-policy --role-name "${S3_LOGS_ROLE_NAME}" --policy-arn "${POLICY_ARN}" 2>/dev/null || true
  aws iam delete-role --role-name "${S3_LOGS_ROLE_NAME}"
fi
if aws iam get-policy --policy-arn "${POLICY_ARN}" >/dev/null 2>&1; then
  # delete-policy fails while non-default versions exist; the create script
  # publishes a new version on every re-run.
  for VERSION in $(aws iam list-policy-versions --policy-arn "${POLICY_ARN}" \
      --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "${POLICY_ARN}" --version-id "${VERSION}"
  done
  log "Deleting IAM policy ${S3_LOGS_POLICY_NAME}..."
  aws iam delete-policy --policy-arn "${POLICY_ARN}"
fi

# --- Bucket ---
if aws s3api head-bucket --bucket "${S3_LOGS_BUCKET}" 2>/dev/null; then
  log "Emptying and deleting bucket ${S3_LOGS_BUCKET}..."
  aws s3 rm "s3://${S3_LOGS_BUCKET}" --recursive >/dev/null
  aws s3api delete-bucket --bucket "${S3_LOGS_BUCKET}" --region "${AWS_REGION}"
fi

success "Pluggable storage logs resources removed."
