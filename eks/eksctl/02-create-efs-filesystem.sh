#!/usr/bin/env bash
#
# 02-efs-filesystem.sh
#
# Creates an Amazon EFS file system for the "acaternberg" EKS cluster, wires up
# the network-level permissions (security group) an EFS mount target needs,
# verifies the IAM role the aws-efs-csi-driver addon relies on, deploys a
# StorageClass for dynamic provisioning, and creates a test PVC + Pod that
# exercises the whole path end-to-end.
#
# PREREQUISITES
#   - config.yaml cluster already created (eksctl create cluster -f config.yaml)
#   - `addons: aws-efs-csi-driver` with `wellKnownPolicies.efsCSIController: true`
#     already applied — this is what actually grants the driver's controller
#     ServiceAccount its IAM permissions (via IRSA). This script only VERIFIES
#     that role exists and falls back to creating it if it's somehow missing
#     (e.g. this script is run against a cluster built without that addon
#     block). It does not duplicate/override what eksctl already set up.
#   - Tools on PATH: aws (CLI v2), eksctl, kubectl, jq
#   - Caller has AWS credentials with EC2/EFS/IAM permissions for this account
#
# WHAT THIS SCRIPT DOES NOT DO
#   - It does not install/upgrade the aws-efs-csi-driver addon itself — that's
#     owned by config.yaml. It only checks the addon + its ServiceAccount
#     are present before trying to use them.
#   - It creates exactly one EFS mount target, in us-east-1a — the only AZ our
#     node groups actually run compute in (see config.yaml). If you later add
#     nodes in another AZ, add a mount target there too, or EFS access from
#     that AZ will incur cross-AZ data transfer / added latency.
#
# Usage: ./02-efs-filesystem.sh
#
set -euo pipefail
source ./.env
# =============================================================================
# CONFIGURATION
# =============================================================================
CLUSTER_NAME="${CLUSTER_NAME:-acaternberg}"
AWS_REGION="${AWS_REGION:-us-east-1}"
TARGET_AZ="${TARGET_AZ:-us-east-1a}"      # must match the AZ our node groups run in
EFS_NAME="${EFS_NAME:-${CLUSTER_NAME}-efs}"
EFS_SG_NAME="${EFS_SG_NAME:-${CLUSTER_NAME}-efs-sg}"
STORAGE_CLASS_NAME="${STORAGE_CLASS_NAME:-efs-sc}"
TEST_NAMESPACE="${TEST_NAMESPACE:-efs-test}"
EFS_CSI_ROLE_NAME="${EFS_CSI_ROLE_NAME:-AmazonEKS_EFS_CSI_DriverRole-${CLUSTER_NAME}}"
EFS_CSI_POLICY_ARN="arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"

# Same tags applied everywhere else in config.yaml — kept in one place so
# every resource this script creates carries them too.
declare -A COMMON_TAGS=(
  [cb-user]="acaternberg"
  [cb-owner]="professional-services"
  [cb-environment]="demo"
)

# =============================================================================
# LOGGING HELPERS
# =============================================================================
log()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# =============================================================================
# 0. PRE-FLIGHT CHECKS
# =============================================================================
for bin in aws eksctl kubectl jq; do
  command -v "$bin" >/dev/null 2>&1 || die "required tool '$bin' not found on PATH"
done

log "Verifying cluster '${CLUSTER_NAME}' exists in ${AWS_REGION}..."
aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null \
  || die "cluster '${CLUSTER_NAME}' not found in ${AWS_REGION} — create it first (config.yaml)"
ok "Cluster found."

log "Verifying aws-efs-csi-driver addon is installed..."
if ! aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name aws-efs-csi-driver \
      --region "$AWS_REGION" >/dev/null 2>&1; then
  die "aws-efs-csi-driver addon is not installed on '${CLUSTER_NAME}'. Apply config.yaml first (it installs this addon with wellKnownPolicies.efsCSIController: true)."
fi
ok "Addon present."

# =============================================================================
# 1. DISCOVER CLUSTER NETWORKING (VPC, subnet, security group)
# =============================================================================
log "Looking up cluster VPC and security group..."
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)
CLUSTER_SG_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
[[ -n "$VPC_ID" && "$VPC_ID" != "None" ]] || die "could not resolve VPC ID for cluster"
[[ -n "$CLUSTER_SG_ID" && "$CLUSTER_SG_ID" != "None" ]] || die "could not resolve cluster security group ID"
ok "VPC: ${VPC_ID} | Cluster security group: ${CLUSTER_SG_ID}"

log "Looking up the private subnet in ${TARGET_AZ}..."
PRIVATE_SUBNET_ID=$(aws ec2 describe-subnets --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
            "Name=availability-zone,Values=${TARGET_AZ}" \
            "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
  --query 'Subnets[0].SubnetId' --output text)
[[ -n "$PRIVATE_SUBNET_ID" && "$PRIVATE_SUBNET_ID" != "None" ]] \
  || die "no private subnet found in ${TARGET_AZ} tagged kubernetes.io/role/internal-elb=1"
ok "Private subnet: ${PRIVATE_SUBNET_ID}"

# =============================================================================
# 2. NETWORK-LEVEL PERMISSIONS: security group allowing NFS (2049) from nodes
# =============================================================================
log "Checking for existing EFS security group '${EFS_SG_NAME}'..."
EFS_SG_ID=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${EFS_SG_NAME}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)

if [[ -z "$EFS_SG_ID" || "$EFS_SG_ID" == "None" ]]; then
  log "Creating security group '${EFS_SG_NAME}'..."
  EFS_SG_ID=$(aws ec2 create-security-group --region "$AWS_REGION" \
    --group-name "$EFS_SG_NAME" \
    --description "Allow NFS (2049) from ${CLUSTER_NAME} nodes to EFS mount targets" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text)

  tag_args=()
  for k in "${!COMMON_TAGS[@]}"; do tag_args+=("Key=${k},Value=${COMMON_TAGS[$k]}"); done
  aws ec2 create-tags --region "$AWS_REGION" --resources "$EFS_SG_ID" \
    --tags "Key=Name,Value=${EFS_SG_NAME}" "${tag_args[@]}"

  aws ec2 authorize-security-group-ingress --region "$AWS_REGION" \
    --group-id "$EFS_SG_ID" \
    --protocol tcp --port 2049 \
    --source-group "$CLUSTER_SG_ID" >/dev/null
  ok "Created ${EFS_SG_ID} with NFS ingress from cluster security group ${CLUSTER_SG_ID}."
else
  ok "Security group already exists: ${EFS_SG_ID}"
fi

# =============================================================================
# 3. EFS FILE SYSTEM
# =============================================================================
log "Checking for an existing EFS file system named '${EFS_NAME}'..."
EFS_ID=$(aws efs describe-file-systems --region "$AWS_REGION" \
  --query "FileSystems[?Tags[?Key=='Name' && Value=='${EFS_NAME}']].FileSystemId" \
  --output text)

if [[ -z "$EFS_ID" ]]; then
  log "Creating EFS file system '${EFS_NAME}'..."
  tag_args="Key=Name,Value=${EFS_NAME}"
  for k in "${!COMMON_TAGS[@]}"; do tag_args="${tag_args} Key=${k},Value=${COMMON_TAGS[$k]}"; done

  EFS_ID=$(aws efs create-file-system --region "$AWS_REGION" \
    --performance-mode generalPurpose \
    --throughput-mode bursting \
    --encrypted \
    --tags $tag_args \
    --query 'FileSystemId' --output text)
  ok "Created file system: ${EFS_ID}"
else
  ok "File system already exists: ${EFS_ID}"
fi

log "Waiting for file system to become available..."
until [[ "$(aws efs describe-file-systems --region "$AWS_REGION" --file-system-id "$EFS_ID" \
            --query 'FileSystems[0].LifeCycleState' --output text)" == "available" ]]; do
  sleep 3
done
ok "File system available."

# =============================================================================
# 4. MOUNT TARGETS (All Private Subnets in VPC)
# =============================================================================
log "Looking up all private subnets in VPC ${VPC_ID}..."
PRIVATE_SUBNET_IDS=$(aws ec2 describe-subnets --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
            "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
  --query 'Subnets[*].SubnetId' --output text)

if [[ -z "$PRIVATE_SUBNET_IDS" || "$PRIVATE_SUBNET_IDS" == "None" ]]; then
  log "No subnets tagged kubernetes.io/role/internal-elb=1 found; looking up non-public subnets in VPC..."
  PRIVATE_SUBNET_IDS=$(aws ec2 describe-subnets --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
              "Name=map-public-ip-on-launch,Values=false" \
    --query 'Subnets[*].SubnetId' --output text)
fi

[[ -n "$PRIVATE_SUBNET_IDS" && "$PRIVATE_SUBNET_IDS" != "None" ]] \
  || die "no private subnets found in VPC ${VPC_ID}"

for subnet_id in $PRIVATE_SUBNET_IDS; do
  log "Checking for mount target in subnet ${subnet_id}..."
  EXISTING_MT=$(aws efs describe-mount-targets --region "$AWS_REGION" --file-system-id "$EFS_ID" \
    --query "MountTargets[?SubnetId=='${subnet_id}'].MountTargetId" --output text)

  if [[ -z "$EXISTING_MT" || "$EXISTING_MT" == "None" ]]; then
    log "Creating mount target in subnet ${subnet_id}..."
    aws efs create-mount-target --region "$AWS_REGION" \
      --file-system-id "$EFS_ID" \
      --subnet-id "$subnet_id" \
      --security-groups "$EFS_SG_ID" >/dev/null
    ok "Mount target requested for ${subnet_id}."
  else
    ok "Mount target already exists in ${subnet_id}: ${EXISTING_MT}"
  fi
done

log "Waiting for all mount targets to become available..."
for subnet_id in $PRIVATE_SUBNET_IDS; do
  until [[ "$(aws efs describe-mount-targets --region "$AWS_REGION" --file-system-id "$EFS_ID" \
              --query "MountTargets[?SubnetId=='${subnet_id}'].LifeCycleState" \
              --output text)" == "available" ]]; do
    sleep 3
  done
done
ok "All mount targets available."

# =============================================================================
# 5. IAM ROLE SAFETY NET
# =============================================================================
# config.yaml's `addons: aws-efs-csi-driver` + `wellKnownPolicies.efsCSIController: true`
# should already have created and wired up this role via IRSA. This step only
# checks that the driver's ServiceAccount is actually annotated with a role —
# and creates one via eksctl as a fallback if, for some reason, it isn't.
log "Verifying efs-csi-controller-sa has an IAM role annotation..."
SA_ROLE_ARN=$(kubectl get serviceaccount efs-csi-controller-sa -n kube-system \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || true)

if [[ -z "$SA_ROLE_ARN" ]]; then
  warn "efs-csi-controller-sa has no IAM role annotation — creating a fallback role via eksctl."
  eksctl create iamserviceaccount \
    --cluster "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --namespace kube-system \
    --name efs-csi-controller-sa \
    --role-name "$EFS_CSI_ROLE_NAME" \
    --attach-policy-arn "$EFS_CSI_POLICY_ARN" \
    --override-existing-serviceaccounts \
    --approve
  ok "Fallback IAM role created and attached."
else
  ok "efs-csi-controller-sa already uses IAM role: ${SA_ROLE_ARN}"
fi

# =============================================================================
# 6. STORAGE CLASS (dynamic provisioning via EFS access points)
# =============================================================================
log "Applying StorageClass '${STORAGE_CLASS_NAME}'..."
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${STORAGE_CLASS_NAME}
  labels:
    cb-user: acaternberg
    cb-owner: professional-services
    cb-environment: demo
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap        # dynamic provisioning: one EFS access point per PVC
  fileSystemId: ${EFS_ID}
  directoryPerms: "700"
  gidRangeStart: "1000"
  gidRangeEnd: "2000"
  basePath: "/dynamic_provisioning"
reclaimPolicy: Delete
volumeBindingMode: Immediate
EOF
ok "StorageClass applied (fileSystemId=${EFS_ID})."

# =============================================================================
# 7. TEST PVC + POD
# =============================================================================
# NOTE: EFS itself is elastic and doesn't enforce a hard quota per access
# point, so the `5Gi` request below is honored by Kubernetes' PVC schema and
# passed through to the access point, but isn't a hard storage ceiling the
# way an EBS volume size would be — this matches how the upstream
# aws-efs-csi-driver dynamic-provisioning example behaves.
log "Creating namespace '${TEST_NAMESPACE}'..."
kubectl create namespace "$TEST_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

log "Creating test PVC + Pod..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: efs-test-claim
  namespace: ${TEST_NAMESPACE}
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ${STORAGE_CLASS_NAME}
  resources:
    requests:
      storage: 5Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: efs-test-pod
  namespace: ${TEST_NAMESPACE}
spec:
  # runs on the "agents" node group, which is tainted workload=agent:NoSchedule
  # (see eksctl-config.yaml.tpl), so the pod needs the matching toleration
  nodeSelector:
    workload: agent
  tolerations:
    - key: workload
      operator: Equal
      value: agent
      effect: NoSchedule
  containers:
    - name: app
      image: public.ecr.aws/docker/library/busybox:latest
      command: ["/bin/sh", "-c", "echo \"hello from \$(hostname) at \$(date -u)\" >> /data/efs-test.log; sleep 3600"]
      volumeMounts:
        - name: efs-storage
          mountPath: /data
  volumes:
    - name: efs-storage
      persistentVolumeClaim:
        claimName: efs-test-claim
  restartPolicy: Never
EOF

log "Waiting for PVC to bind (up to 2 minutes)..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound \
  pvc/efs-test-claim -n "$TEST_NAMESPACE" --timeout=120s \
  || die "PVC did not bind — check 'kubectl describe pvc efs-test-claim -n ${TEST_NAMESPACE}'"
ok "PVC bound."

log "Waiting for test pod to become Ready (up to 2 minutes)..."
kubectl wait --for=condition=Ready pod/efs-test-pod -n "$TEST_NAMESPACE" --timeout=120s \
  || warn "Pod not Ready yet — check 'kubectl describe pod efs-test-pod -n ${TEST_NAMESPACE}' and 'kubectl logs efs-test-pod -n ${TEST_NAMESPACE}'"

echo
ok "Done. Summary:"
echo "  EFS file system ID : ${EFS_ID}"
echo "  EFS security group : ${EFS_SG_ID}"
echo "  StorageClass       : ${STORAGE_CLASS_NAME}"
echo "  Test namespace     : ${TEST_NAMESPACE}"
echo
echo "Verify the mount worked:"
echo "  kubectl exec -n ${TEST_NAMESPACE} efs-test-pod -- cat /data/efs-test.log"
echo
echo "Clean up the test resources (leaves the EFS file system and StorageClass in place):"
echo "  kubectl delete namespace ${TEST_NAMESPACE}"