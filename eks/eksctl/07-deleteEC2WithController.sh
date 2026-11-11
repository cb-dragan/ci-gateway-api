#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 07-deleteEC2WithController.sh — Tear down everything 07-createEC2WithController.sh
# created for the standalone EC2 CloudBees CI Client Controller.
#
# ORDER MATTERS, and it's the reverse of create:
#   listener rule -> target group -> (ACM cert, opt-in) -> EC2 instance ->
#   cluster SG rule -> security group -> IAM instance profile/role -> Route53 record
# The listener rule must go before the target group (a target group cannot be
# deleted while a rule still forwards to it), and the security group must go
# after instance termination (its ENI attachment isn't released until then)
# and after the cluster security group's rule referencing it is revoked (AWS
# refuses to delete a security group still referenced as a source elsewhere).
#
# WHAT THIS DOES NOT DELETE (shared with / owned by the EKS cluster)
#   - The VPC, subnets, and their kubernetes.io/* tags (eksctl-owned).
#   - The shared ALB, its security group, and its HTTPS listener/default
#     certificate (owned by 04-installEnvoy.sh / the cjoc-alb Ingress) — only
#     the host-header RULE this script's create counterpart added is removed.
#   - The EKS cluster security group itself — only the one 443 rule this
#     script's create counterpart added (scoped to this instance's own SG) is
#     revoked.
#   - The Route53 hosted zone itself, and any record other than the single
#     EC2_HOST_NAME alias A record.
#   - The ACM certificate, by default (reusable across rebuilds; DNS
#     validation takes minutes). Opt in with --delete-cert.
#
# Usage:
#   ./07-deleteEC2WithController.sh                # everything above except the cert
#   ./07-deleteEC2WithController.sh --delete-cert  # also delete the ACM certificate
#   ./07-deleteEC2WithController.sh --yes          # skip the confirmation prompt
# -----------------------------------------------------------------------------
set -euo pipefail

source ./.env
source ./lib-acm.sh

log()     { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

for bin in aws kubectl jq; do
  command -v "$bin" >/dev/null 2>&1 || error "required tool '$bin' not found on PATH"
done

DELETE_CERT=false
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --delete-cert) DELETE_CERT=true ;;
    --yes|-y)      ASSUME_YES=true ;;
    -h|--help)     sed -n '2,26p' "$0"; exit 0 ;;
    *)             error "unknown flag '$1' (try --help)" ;;
  esac
  shift
done

# =============================================================================
# CONFIG — must match 07-createEC2WithController.sh exactly so the same
# resource names/tags are targeted.
# =============================================================================
AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
EC2_HOST_NAME="${EC2_CONTROLLER_HOST_NAME:-ec2-controller.acaternberg.aws.ps.beescloud.com}"
EC2_INSTANCE_NAME="${EC2_CONTROLLER_INSTANCE_NAME:-${CLUSTER_NAME}-ec2-controller}"
EC2_CONTROLLER_PORT="${EC2_CONTROLLER_PORT:-8080}"

ENVOY_GW_NAMESPACE="${ENVOY_GW_NAMESPACE:?ENVOY_GW_NAMESPACE must be set in .env (namespace of the existing cjoc-alb Ingress)}"

ROUTE53_ZONE_DOMAIN="${ROUTE53_ZONE_DOMAIN:-$(cut -d. -f2- <<< "$EC2_HOST_NAME")}"

IAM_ROLE_NAME="${EC2_INSTANCE_NAME}-role"
IAM_INSTANCE_PROFILE_NAME="${EC2_INSTANCE_NAME}-profile"
SG_NAME="${EC2_INSTANCE_NAME}-sg"
TG_NAME="${EC2_INSTANCE_NAME}-tg"

# =============================================================================
# 0. CONFIRM
# =============================================================================
echo
warn "About to delete (AWS account resources only — nothing in the EKS cluster):"
echo "    - ALB listener rule forwarding host '${EC2_HOST_NAME}'"
echo "    - Target group ${TG_NAME}"
echo "    - EC2 instance '${EC2_INSTANCE_NAME}'"
echo "    - Security group ${SG_NAME}"
echo "    - IAM instance profile ${IAM_INSTANCE_PROFILE_NAME} and role ${IAM_ROLE_NAME}"
echo "    - Route53 A record ${EC2_HOST_NAME}"
$DELETE_CERT && echo "    - the ACM certificate for ${EC2_HOST_NAME}"
echo
echo "  Keeping: the VPC/subnets, the shared ALB + its security group and HTTPS"
echo "  listener/default certificate, the EKS cluster, and the Route53 hosted zone."
echo

if [[ "$ASSUME_YES" != true ]]; then
  read -r -p "Proceed? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }
fi

# =============================================================================
# 1. RESOLVE VPC (read-only — needed to scope the security-group lookup)
# =============================================================================
log "Resolving VPC for cluster '${CLUSTER_NAME}'..."
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || true)
if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
  success "VPC: ${VPC_ID}"
else
  warn "Could not resolve VPC for cluster ${CLUSTER_NAME} — security group lookup will be skipped."
  VPC_ID=""
fi

# =============================================================================
# 2. RESOLVE THE SHARED ALB (best-effort — only needed for the rule/cert steps;
#    the shared ALB, its listener and its default certificate are NEVER touched)
# =============================================================================
LISTENER_ARN=""
log "Resolving shared ALB from Ingress cjoc-alb (namespace ${ENVOY_GW_NAMESPACE})..."
ALB_DNS=$(kubectl get ingress cjoc-alb -n "$ENVOY_GW_NAMESPACE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
if [[ -n "$ALB_DNS" ]]; then
  ALB_ARN=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
    --query "LoadBalancers[?DNSName=='${ALB_DNS}'].LoadBalancerArn | [0]" --output text 2>/dev/null || true)
  if [[ -n "$ALB_ARN" && "$ALB_ARN" != "None" ]]; then
    LISTENER_ARN=$(aws elbv2 describe-listeners --region "$AWS_REGION" --load-balancer-arn "$ALB_ARN" \
      --query "Listeners[?Port==\`443\`].ListenerArn | [0]" --output text 2>/dev/null || true)
    [[ "$LISTENER_ARN" == "None" ]] && LISTENER_ARN=""
  fi
fi
if [[ -n "$LISTENER_ARN" ]]; then
  success "Shared ALB HTTPS listener resolved."
else
  warn "Shared ALB/listener not found — skipping listener-rule and certificate-detach steps."
fi

# =============================================================================
# 3. DELETE THE LISTENER RULE (must happen before the target group is deleted)
# =============================================================================
if [[ -n "$LISTENER_ARN" ]]; then
  log "Checking for a listener rule forwarding host '${EC2_HOST_NAME}'..."
  RULE_ARN=$(aws elbv2 describe-rules --region "$AWS_REGION" --listener-arn "$LISTENER_ARN" \
    --query "Rules[?Conditions[?Field=='host-header' && contains(Values, '${EC2_HOST_NAME}')]].RuleArn | [0]" \
    --output text 2>/dev/null || true)
  if [[ -n "$RULE_ARN" && "$RULE_ARN" != "None" ]]; then
    aws elbv2 delete-rule --region "$AWS_REGION" --rule-arn "$RULE_ARN" >/dev/null
    success "Listener rule deleted."
  else
    log "No listener rule found for '${EC2_HOST_NAME}'; skipping."
  fi
fi

# =============================================================================
# 4. DEREGISTER TARGET + DELETE TARGET GROUP
# =============================================================================
log "Checking for target group '${TG_NAME}'..."
TG_ARN=$(aws elbv2 describe-target-groups --region "$AWS_REGION" --names "$TG_NAME" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)

if [[ -n "$TG_ARN" && "$TG_ARN" != "None" ]]; then
  REGISTERED_IDS=$(aws elbv2 describe-target-health --region "$AWS_REGION" --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[].Target.Id' --output text 2>/dev/null || true)
  for id in $REGISTERED_IDS; do
    log "Deregistering target ${id}..."
    aws elbv2 deregister-targets --region "$AWS_REGION" --target-group-arn "$TG_ARN" \
      --targets "Id=${id},Port=${EC2_CONTROLLER_PORT}" >/dev/null 2>&1 || true
  done

  log "Deleting target group '${TG_NAME}'..."
  aws elbv2 delete-target-group --region "$AWS_REGION" --target-group-arn "$TG_ARN" >/dev/null
  success "Target group deleted."
else
  log "No target group '${TG_NAME}' found; skipping."
fi

# =============================================================================
# 5. ACM CERTIFICATE (opt-in — detach from the shared listener, then delete)
# =============================================================================
if [[ "$DELETE_CERT" == true ]]; then
  log "Looking up the ACM certificate for '${EC2_HOST_NAME}'..."
  CERT_ARN=$(aws acm list-certificates --region "$AWS_REGION" \
    --query "CertificateSummaryList[?DomainName=='${EC2_HOST_NAME}'].CertificateArn | [0]" \
    --output text 2>/dev/null || true)

  if [[ -n "$CERT_ARN" && "$CERT_ARN" != "None" ]]; then
    # 07-createEC2WithController.sh folded this ARN into the cjoc-alb Ingress
    # annotation (so the AWS Load Balancer Controller keeps it on the listener).
    # Take it out again, or the controller keeps trying to attach a deleted cert.
    CURRENT_CERT_ARNS=$(kubectl get ingress cjoc-alb -n "$ENVOY_GW_NAMESPACE" \
      -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/certificate-arn}' 2>/dev/null || true)
    if [[ ",${CURRENT_CERT_ARNS}," == *",${CERT_ARN},"* ]]; then
      REMAINING_CERT_ARNS=$(tr ',' '\n' <<< "$CURRENT_CERT_ARNS" | grep -vxF "$CERT_ARN" | paste -sd, - || true)
      if [[ -n "$REMAINING_CERT_ARNS" ]]; then
        kubectl annotate ingress cjoc-alb -n "$ENVOY_GW_NAMESPACE" \
          "alb.ingress.kubernetes.io/certificate-arn=${REMAINING_CERT_ARNS}" --overwrite >/dev/null
        success "Certificate removed from the cjoc-alb Ingress annotation."
      else
        warn "The EC2 certificate is the only one on the cjoc-alb annotation; leaving the annotation as it is."
      fi
    fi

    if [[ -n "$LISTENER_ARN" ]]; then
      IS_DEFAULT=$(aws elbv2 describe-listener-certificates --region "$AWS_REGION" --listener-arn "$LISTENER_ARN" \
        --query "Certificates[?CertificateArn=='${CERT_ARN}'].IsDefault | [0]" --output text 2>/dev/null || true)
      if [[ "$IS_DEFAULT" == "True" ]]; then
        warn "Certificate ${CERT_ARN} is the listener's DEFAULT certificate (shared) — not detaching or deleting it."
      else
        log "Detaching certificate from the shared listener (if attached)..."
        aws elbv2 remove-listener-certificates --region "$AWS_REGION" --listener-arn "$LISTENER_ARN" \
          --certificates "CertificateArn=${CERT_ARN}" >/dev/null 2>&1 || true
        log "Deleting certificate ${CERT_ARN} (and its Route53 validation record)..."
        delete_acm_certificate "$CERT_ARN" "$ROUTE53_ZONE_DOMAIN"
      fi
    else
      log "Deleting certificate ${CERT_ARN} (listener not resolved, so no detach step was needed)..."
      delete_acm_certificate "$CERT_ARN" "$ROUTE53_ZONE_DOMAIN"
    fi
  else
    log "No certificate found for '${EC2_HOST_NAME}'."
  fi
else
  log "Leaving the ACM certificate in place (pass --delete-cert to remove it)."
fi

# =============================================================================
# 6. TERMINATE THE EC2 INSTANCE
# =============================================================================
log "Checking for an EC2 instance named '${EC2_INSTANCE_NAME}'..."
INSTANCE_ID=$(aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:Name,Values=${EC2_INSTANCE_NAME}" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)

if [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]]; then
  log "Terminating instance ${INSTANCE_ID}..."
  aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" >/dev/null
  log "Waiting for instance to terminate..."
  aws ec2 wait instance-terminated --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
  success "Instance terminated: ${INSTANCE_ID}"
else
  log "No instance named '${EC2_INSTANCE_NAME}' found; skipping."
fi

# =============================================================================
# 7. DELETE THE SECURITY GROUP (its ENI attachment releases a few seconds
#    after instance termination, so retry briefly instead of failing outright)
# =============================================================================
if [[ -n "$VPC_ID" ]]; then
  log "Checking for security group '${SG_NAME}'..."
  EC2_SG_ID=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${SG_NAME}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)

  if [[ -n "$EC2_SG_ID" && "$EC2_SG_ID" != "None" ]]; then
    # The EKS cluster security group may hold a rule referencing this SG as a
    # source (added by 07-createEC2WithController.sh to let this instance
    # reach the K8s API on 443) — AWS refuses to delete a security group that
    # is still referenced as a source in another group's rules, so that rule
    # must be revoked first.
    log "Resolving EKS cluster security group..."
    CLUSTER_SG_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
      --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text 2>/dev/null || true)
    if [[ -n "$CLUSTER_SG_ID" && "$CLUSTER_SG_ID" != "None" ]]; then
      log "Revoking cluster security group's 443 rule for ${SG_NAME} (if present)..."
      aws ec2 revoke-security-group-ingress --region "$AWS_REGION" --group-id "$CLUSTER_SG_ID" \
        --protocol tcp --port 443 --source-group "$EC2_SG_ID" >/dev/null 2>&1 \
        && success "Cluster security group rule revoked." \
        || log "No matching rule on ${CLUSTER_SG_ID}; skipping."
    else
      warn "Could not resolve cluster security group — skipping revoke (deleting ${SG_NAME} may fail if the rule is still present)."
    fi

    log "Deleting security group ${EC2_SG_ID}..."
    DELETED=false
    for _ in $(seq 1 6); do
      if aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$EC2_SG_ID" 2>/tmp/delete-sg.err; then
        DELETED=true
        break
      fi
      warn "delete-security-group failed (ENI likely still detaching), retrying in 10s..."
      sleep 10
    done
    if [[ "$DELETED" == true ]]; then
      success "Security group deleted: ${EC2_SG_ID}"
    else
      warn "Could not delete security group ${EC2_SG_ID} — check for lingering ENIs:"
      cat /tmp/delete-sg.err >&2 || true
    fi
  else
    log "No security group '${SG_NAME}' found; skipping."
  fi
else
  warn "Skipping security group lookup/deletion — VPC could not be resolved."
fi

# =============================================================================
# 8. IAM INSTANCE PROFILE + ROLE
# =============================================================================
log "Checking for instance profile '${IAM_INSTANCE_PROFILE_NAME}'..."
if aws iam get-instance-profile --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
  aws iam remove-role-from-instance-profile \
    --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1 || true
  aws iam delete-instance-profile --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" >/dev/null
  success "Instance profile deleted: ${IAM_INSTANCE_PROFILE_NAME}"
else
  log "No instance profile '${IAM_INSTANCE_PROFILE_NAME}' found; skipping."
fi

log "Checking for IAM role '${IAM_ROLE_NAME}'..."
if aws iam get-role --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1; then
  aws iam detach-role-policy --role-name "$IAM_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null 2>&1 || true
  aws iam delete-role --role-name "$IAM_ROLE_NAME" >/dev/null
  success "IAM role deleted: ${IAM_ROLE_NAME}"
else
  log "No IAM role '${IAM_ROLE_NAME}' found; skipping."
fi

# =============================================================================
# 9. ROUTE53 A RECORD — fetch the exact existing record set and delete that,
#    since Route53 rejects a DELETE unless the values match precisely.
# =============================================================================
log "Resolving hosted zone for '${ROUTE53_ZONE_DOMAIN}'..."
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "${ROUTE53_ZONE_DOMAIN}." \
  --query "HostedZones[?Name=='${ROUTE53_ZONE_DOMAIN}.'].Id | [0]" \
  --output text 2>/dev/null | sed 's#/hostedzone/##' || true)

if [[ -n "$HOSTED_ZONE_ID" && "$HOSTED_ZONE_ID" != "None" ]]; then
  log "Looking up the existing A record for '${EC2_HOST_NAME}'..."
  EXISTING_RECORD=$(aws route53 list-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
    --query "ResourceRecordSets[?Name=='${EC2_HOST_NAME}.' && Type=='A'] | [0]" --output json 2>/dev/null || true)

  if [[ -n "$EXISTING_RECORD" && "$EXISTING_RECORD" != "null" ]]; then
    log "Deleting Route53 A record ${EC2_HOST_NAME}..."
    aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
      --change-batch "$(jq -n --argjson rrs "$EXISTING_RECORD" '{Changes:[{Action:"DELETE",ResourceRecordSet:$rrs}]}')" \
      >/dev/null
    success "Route53 A record deleted."
  else
    log "No A record found for '${EC2_HOST_NAME}'; skipping."
  fi
else
  warn "No public hosted zone found for '${ROUTE53_ZONE_DOMAIN}' — skipping Route53 cleanup."
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo
success "Teardown complete."
echo
echo "Still present (by design):"
echo "  - VPC/subnets and the EKS cluster '${CLUSTER_NAME}'"
echo "  - The shared ALB, its security group, and its HTTPS listener/default certificate"
echo "  - The Route53 hosted zone for ${ROUTE53_ZONE_DOMAIN}"
$DELETE_CERT || echo "  - ACM certificate for ${EC2_HOST_NAME} (pass --delete-cert to remove it)"
