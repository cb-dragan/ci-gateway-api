#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 04-deleteNginx.sh — Tear down ingress-nginx and its public NLB. Counterpart of
# 04-installNginx.sh; mirrors 04-deleteEnvoy.sh.
#
# ORDER MATTERS. The AWS Load Balancer Controller deprovisions the NLB via a
# finalizer on the ingress-nginx Service. The Helm release is uninstalled first
# and the NLB is waited on. Delete the namespace (or the controller) first and
# the finalizer has nobody to remove it: namespace deletion wedges in
# Terminating and the NLB is orphaned, still billing.
#
# WHAT THIS DOES NOT DELETE (by default)
#   - The CloudBees namespace (${NAMESPACE_CLOUDBEES}) and CloudBees CI itself.
#   - The CloudBees Ingresses of class nginx. They stop serving traffic once
#     nginx is gone. Run this after the migration (see
#     09-migrationCleanupIngress.sh) or as part of a full teardown.
#   - The ACM certificate. It is reusable and 04-installEnvoy.sh uses the same
#     one. Opt in with --delete-cert (ACM refuses while a load balancer uses it).
#
# Usage:
#   ./04-deleteNginx.sh                 # ingress-nginx + NLB
#   ./04-deleteNginx.sh --delete-cert   # also delete the ACM certificate
#   ./04-deleteNginx.sh --yes           # skip the confirmation prompt
# -----------------------------------------------------------------------------
set -euo pipefail

source ./.env

log()     { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

DELETE_CERT=false
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --delete-cert) DELETE_CERT=true ;;
    --yes|-y)      ASSUME_YES=true ;;
    -h|--help)     awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *)             error "unknown flag '$1' (try --help)" ;;
  esac
  shift
done

AWS_REGION=${AWS_DEFAULT_REGION:-us-east-1}
INGRESS_NGINX_NAMESPACE=${INGRESS_NGINX_NAMESPACE:-ingress-nginx}
INGRESS_CLASS_NAME=${INGRESS_CLASS_NAME:-nginx}

# =============================================================================
# 0. CONFIRM
# =============================================================================
NLB_DNS=$(kubectl get svc ingress-nginx-controller -n "${INGRESS_NGINX_NAMESPACE}" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

# Ingresses of our class, any namespace. They go dark when nginx is removed.
LEFTOVER=$(kubectl get ingress -A --no-headers \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,CLASS:.spec.ingressClassName 2>/dev/null \
  | awk -v c="${INGRESS_CLASS_NAME}" '$3==c {print "    - " $1 "/" $2}' || true)

echo
warn "About to delete from cluster '$(kubectl config current-context 2>/dev/null || echo unknown)':"
echo "    - Helm release 'ingress-nginx' and namespace ${INGRESS_NGINX_NAMESPACE}"
echo "    - the public NLB ${NLB_DNS:-(none found)}"
$DELETE_CERT && echo "    - the ACM certificate for ${CJOC_HOST_NAME}"
echo
echo "  Keeping: namespace ${NAMESPACE_CLOUDBEES} and everything CloudBees CI owns."
echo
if [[ -n "${LEFTOVER}" ]]; then
  warn "These Ingresses use class '${INGRESS_CLASS_NAME}' and stop serving traffic after this:"
  echo "${LEFTOVER}"
  echo
fi

if [[ "$ASSUME_YES" != true ]]; then
  read -r -p "Proceed? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }
fi

# =============================================================================
# 1. HELM RELEASE — must go first, while the LB Controller can still act
# =============================================================================
if helm status ingress-nginx -n "${INGRESS_NGINX_NAMESPACE}" &>/dev/null; then
  log "Uninstalling the ingress-nginx Helm release (deprovisions the NLB)..."
  helm uninstall ingress-nginx -n "${INGRESS_NGINX_NAMESPACE}" --wait --timeout 10m \
    || warn "helm uninstall reported an error - check the NLB was actually removed in the console."
  success "Helm release removed."
else
  log "No ingress-nginx Helm release found; skipping."
fi

# =============================================================================
# 2. NLB — confirm it is really gone before touching the namespace
# =============================================================================
if [[ -n "${NLB_DNS}" ]]; then
  log "Waiting for the NLB to disappear..."
  NLB_GONE=false
  for _ in $(seq 1 30); do
    LB_ARN=$(aws elbv2 describe-load-balancers --region "${AWS_REGION}" \
      --query "LoadBalancers[?DNSName=='${NLB_DNS}'].LoadBalancerArn | [0]" --output text 2>/dev/null || echo "None")
    if [[ -z "${LB_ARN}" || "${LB_ARN}" == "None" ]]; then NLB_GONE=true; break; fi
    sleep 10
  done
  [[ "${NLB_GONE}" == true ]] && success "NLB removed." \
    || warn "NLB still present after 5 min: ${LB_ARN}. Check the AWS console; it bills until deleted."
fi

# =============================================================================
# 3. NAMESPACE
# =============================================================================
log "Deleting namespace ${INGRESS_NGINX_NAMESPACE}..."
kubectl delete ns "${INGRESS_NGINX_NAMESPACE}" --ignore-not-found --timeout=300s \
  || warn "Namespace deletion timed out - inspect with: kubectl get all -n ${INGRESS_NGINX_NAMESPACE}"
success "ingress-nginx uninstalled."

# =============================================================================
# 4. ACM CERTIFICATE (opt-in)
# =============================================================================
if [[ "$DELETE_CERT" == true ]]; then
  log "Looking up the ACM certificate for '${CJOC_HOST_NAME}'..."
  CERT_ARN=$(aws acm list-certificates --region "${AWS_REGION}" \
    --query "CertificateSummaryList[?DomainName=='${CJOC_HOST_NAME}'].CertificateArn | [0]" \
    --output text 2>/dev/null || true)

  if [[ -n "${CERT_ARN}" && "${CERT_ARN}" != "None" ]]; then
    # ACM refuses to delete a certificate still attached to a load balancer, so
    # this only succeeds once the NLB above (and the Envoy ALB) are really gone.
    log "Deleting ${CERT_ARN}..."
    aws acm delete-certificate --region "${AWS_REGION}" --certificate-arn "${CERT_ARN}" \
      && success "Certificate deleted." \
      || warn "Could not delete ${CERT_ARN} - it is probably still in use by a load balancer."
  else
    log "No certificate found for '${CJOC_HOST_NAME}'."
  fi
else
  log "Leaving the ACM certificate in place (pass --delete-cert to remove it)."
fi

echo
success "Teardown complete."
echo
echo "Still present (by design):"
echo "  - namespace ${NAMESPACE_CLOUDBEES} and CloudBees CI"
$DELETE_CERT || echo "  - ACM certificate for ${CJOC_HOST_NAME}"
echo
echo "Route53 records for ${CJOC_HOST_NAME} are owned by external-dns; with"
echo "policy=sync it removes them once the Ingress is gone. Verify with:"
echo "  kubectl logs -n ${NAMESPACE_EXTERNAL_DNS:-external-dns} deploy/external-dns --tail=50"
