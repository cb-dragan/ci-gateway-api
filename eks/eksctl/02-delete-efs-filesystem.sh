#!/usr/bin/env bash
#
# 02-delete-efs-filesystem.sh
#
# Clean up all EFS-related resources created by 02-create-efs-filesystem.sh:
#   1. Test Namespace (PVC + Pod)
#   2. Kubernetes StorageClass
#   3. Fallback IAM ServiceAccount / Role (if created by script)
#   4. EFS Mount Targets
#   5. EFS File System
#   6. EFS Security Group
#
# DESTRUCTIVE: the file system and all data on it are gone. Asks you to type the
# EFS name first. Fails (instead of reporting success) if the security group
# cannot be deleted, because a leftover group blocks VPC deletion later.
#
# Usage: ./02-delete-efs-filesystem.sh [--yes]     # --yes skips the confirmation
#
set -euo pipefail

source ./.env

CLUSTER_NAME="${CLUSTER_NAME:-acaternberg}"
AWS_REGION="${AWS_REGION:-us-east-1}"
EFS_NAME="${EFS_NAME:-${CLUSTER_NAME}-efs}"
EFS_SG_NAME="${EFS_SG_NAME:-${CLUSTER_NAME}-efs-sg}"
STORAGE_CLASS_NAME="${STORAGE_CLASS_NAME:-efs-sc}"
TEST_NAMESPACE="${TEST_NAMESPACE:-efs-test}"
EFS_CSI_ROLE_NAME="${EFS_CSI_ROLE_NAME:-AmazonEKS_EFS_CSI_DriverRole-${CLUSTER_NAME}}"

log()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }

ASSUME_YES=false
for arg in "$@"; do
  case "$arg" in
    --yes|-y)  ASSUME_YES=true ;;
    -h|--help) awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *)         echo "unknown flag '$arg' (try --help)" >&2; exit 1 ;;
  esac
done

echo "This will permanently delete:"
echo "  - EFS file system '${EFS_NAME}' and ALL data on it (JENKINS_HOME of anything on StorageClass '${STORAGE_CLASS_NAME}')"
echo "  - its mount targets and security group '${EFS_SG_NAME}'"
echo "  - StorageClass '${STORAGE_CLASS_NAME}' and namespace '${TEST_NAMESPACE}'"
if [[ "$ASSUME_YES" != true ]]; then
  read -r -p "Type the EFS name to confirm: " CONFIRM
  [[ "$CONFIRM" == "$EFS_NAME" ]] || { echo "Confirmation did not match; aborting." >&2; exit 1; }
fi

# 1. Delete test namespace if it exists
if kubectl get namespace "$TEST_NAMESPACE" >/dev/null 2>&1; then
  log "Deleting test namespace '${TEST_NAMESPACE}'..."
  kubectl delete namespace "$TEST_NAMESPACE" --ignore-not-found=true
  ok "Namespace deleted."
fi

# 2. Delete StorageClass if it exists
if kubectl get storageclass "$STORAGE_CLASS_NAME" >/dev/null 2>&1; then
  log "Deleting StorageClass '${STORAGE_CLASS_NAME}'..."
  kubectl delete storageclass "$STORAGE_CLASS_NAME" --ignore-not-found=true
  ok "StorageClass deleted."
fi

# 3. Delete fallback iamserviceaccount if created
log "Checking for fallback iamserviceaccount..."
if eksctl get iamserviceaccount --cluster "$CLUSTER_NAME" --region "$AWS_REGION" --namespace kube-system --name efs-csi-controller-sa >/dev/null 2>&1; then
  log "Deleting iamserviceaccount 'efs-csi-controller-sa'..."
  eksctl delete iamserviceaccount --cluster "$CLUSTER_NAME" --region "$AWS_REGION" --namespace kube-system --name efs-csi-controller-sa || true
  ok "IAM ServiceAccount cleaned up."
fi

# 4. Find & Delete EFS File System and Mount Targets
log "Looking up EFS file system '${EFS_NAME}'..."
EFS_ID=$(aws efs describe-file-systems --region "$AWS_REGION" \
  --query "FileSystems[?Tags[?Key=='Name' && Value=='${EFS_NAME}']].FileSystemId" \
  --output text 2>/dev/null || true)

if [[ -n "$EFS_ID" && "$EFS_ID" != "None" ]]; then
  log "Found file system ${EFS_ID}. Fetching mount targets..."
  MT_IDS=$(aws efs describe-mount-targets --region "$AWS_REGION" --file-system-id "$EFS_ID" \
    --query "MountTargets[*].MountTargetId" --output text)

  for mt in $MT_IDS; do
    if [[ -n "$mt" && "$mt" != "None" ]]; then
      log "Deleting mount target ${mt}..."
      aws efs delete-mount-target --region "$AWS_REGION" --mount-target-id "$mt"
    fi
  done

  if [[ -n "$MT_IDS" ]]; then
    log "Waiting for mount targets to be fully deleted..."
    while true; do
      REMAINING=$(aws efs describe-mount-targets --region "$AWS_REGION" --file-system-id "$EFS_ID" \
        --query "MountTargets[*].MountTargetId" --output text 2>/dev/null || true)
      [[ -z "$REMAINING" || "$REMAINING" == "None" ]] && break
      sleep 5
    done
    ok "All mount targets deleted."
  fi

  log "Deleting EFS file system ${EFS_ID}..."
  aws efs delete-file-system --region "$AWS_REGION" --file-system-id "$EFS_ID"
  ok "EFS file system deleted."
else
  ok "No EFS file system named '${EFS_NAME}' found."
fi

# 5. Delete Security Group
log "Looking up security group '${EFS_SG_NAME}'..."
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || true)

if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
  EFS_SG_ID=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${EFS_SG_NAME}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)

  if [[ -n "$EFS_SG_ID" && "$EFS_SG_ID" != "None" ]]; then
    log "Deleting security group ${EFS_SG_ID}..."
    # The ENIs of the deleted mount targets can take a few minutes to go away.
    SG_DELETED=false
    for _ in $(seq 1 30); do
      if aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$EFS_SG_ID" 2>/dev/null; then
        SG_DELETED=true
        ok "Security group deleted."
        break
      fi
      log "Security group still in use, waiting 10 seconds..."
      sleep 10
    done
    # Not part of the eksctl stacks: if it stays, deleting the VPC fails later.
    if [[ "$SG_DELETED" != true ]]; then
      echo "[ERROR] Could not delete security group ${EFS_SG_ID}. Look for ENIs still using it:" >&2
      echo "  aws ec2 describe-network-interfaces --region ${AWS_REGION} --filters Name=group-id,Values=${EFS_SG_ID}" >&2
      exit 1
    fi
  else
    ok "Security group '${EFS_SG_NAME}' not found."
  fi
fi

echo
ok "EFS cleanup completed successfully."
