#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 04-deleteEnvoy.sh — Tear down Envoy Gateway, the Gateway API resources and
# the public ALB. Extracted from the front of 04-installEnvoy.sh, which used to
# uninstall before every install.
#
# ORDER MATTERS. The Ingress is deleted first and waited on, because the AWS
# Load Balancer Controller deprovisions the ALB via a finalizer on that
# Ingress. Delete the namespace (or the controller) first and the finalizer has
# nobody to remove it: namespace deletion wedges in Terminating and the ALB is
# orphaned, still billing.
#
# WHAT THIS DOES NOT DELETE (by default)
#   - The CloudBees namespace (${NAMESPACE_CLOUDBEES}). That is 04's to own,
#     and dropping it here would take CJOC and every controller with it.
#   - The Gateway API / Envoy Gateway CRDs. They are cluster-scoped, so
#     removing them would cascade-delete every Gateway and HTTPRoute in the
#     cluster, not just ours. Opt in with --delete-crds.
#   - The ACM certificate. It is reusable across rebuilds and validation takes
#     minutes. Opt in with --delete-cert (also removes its Route53 validation record).
#
# Usage:
#   ./04-deleteEnvoy.sh                 # Envoy Gateway + Gateway resources + ALB
#   ./04-deleteEnvoy.sh --delete-crds   # also remove the CRDs (cluster-wide!)
#   ./04-deleteEnvoy.sh --delete-cert   # also delete the ACM certificate
#   ./04-deleteEnvoy.sh --yes           # skip the confirmation prompt
# -----------------------------------------------------------------------------
set -euo pipefail

source ./.env
source ./lib-acm.sh

log()     { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

DELETE_CRDS=false
DELETE_CERT=false
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --delete-crds) DELETE_CRDS=true ;;
    --delete-cert) DELETE_CERT=true ;;
    --yes|-y)      ASSUME_YES=true ;;
    -h|--help)     sed -n '2,27p' "$0"; exit 0 ;;
    *)             error "unknown flag '$1' (try --help)" ;;
  esac
  shift
done

AWS_REGION=${AWS_DEFAULT_REGION:-us-east-1}

# =============================================================================
# 0. CONFIRM
# =============================================================================
echo
warn "About to delete from cluster '$(kubectl config current-context 2>/dev/null || echo unknown)':"
echo "    - Ingress cjoc-alb in ${ENVOY_GW_NAMESPACE} (destroys the public ALB)"
echo "    - Gateway ${GATEWAY_NAME} + ClientTrafficPolicy in ${NAMESPACE_CLOUDBEES}"
echo "    - GatewayClass eg, EnvoyProxy eg-aws-lb"
echo "    - Helm release 'eg' and namespace ${ENVOY_GW_NAMESPACE}"
$DELETE_CRDS && echo "    - Gateway API + Envoy Gateway CRDs (CLUSTER-WIDE)"
$DELETE_CERT && echo "    - the ACM certificate for ${CJOC_HOST_NAME}"
echo
echo "  Keeping: namespace ${NAMESPACE_CLOUDBEES} and everything CloudBees CI owns."
echo

if [[ "$ASSUME_YES" != true ]]; then
  read -r -p "Proceed? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }
fi

# =============================================================================
# 1. INGRESS / ALB — must go first, while the controller can still act
# =============================================================================
if kubectl get ingress cjoc-alb -n "${ENVOY_GW_NAMESPACE}" &>/dev/null; then
  log "Deleting Ingress cjoc-alb (deprovisions the ALB)..."
  kubectl delete ingress cjoc-alb -n "${ENVOY_GW_NAMESPACE}" --wait=true --timeout=300s \
    || warn "Ingress deletion timed out — check the ALB was actually removed in the console."
  success "Ingress deleted."
else
  log "No cjoc-alb Ingress found; skipping."
fi

# Terraform's equivalent stable Service, if the tf/ stack created it.
kubectl delete service "envoy-${GATEWAY_NAME}-stable" -n "${ENVOY_GW_NAMESPACE}" \
  --ignore-not-found &>/dev/null || true

# =============================================================================
# 2. GATEWAY API RESOURCES
# =============================================================================
log "Deleting ClientTrafficPolicy and Gateway..."
kubectl delete clienttrafficpolicy keep-escaped-slashes -n "${NAMESPACE_CLOUDBEES}" \
  --ignore-not-found &>/dev/null || true
kubectl delete gateway "${GATEWAY_NAME}" -n "${NAMESPACE_CLOUDBEES}" \
  --ignore-not-found --timeout=120s || true

# Finalizer stripping is a fallback, not the happy path: it only helps when the
# Envoy Gateway controller is already gone and cannot reconcile the deletion.
# Doing it up front (as the old inline block did) can leak the Envoy Service.
if kubectl get gateway "${GATEWAY_NAME}" -n "${NAMESPACE_CLOUDBEES}" &>/dev/null; then
  warn "Gateway still present — clearing finalizers to unblock deletion."
  kubectl patch gateway "${GATEWAY_NAME}" -n "${NAMESPACE_CLOUDBEES}" \
    -p '{"metadata":{"finalizers":null}}' --type=merge &>/dev/null || true
fi

log "Deleting GatewayClass and EnvoyProxy..."
kubectl delete gatewayclass eg --ignore-not-found --timeout=120s || true
if kubectl get gatewayclass eg &>/dev/null; then
  warn "GatewayClass still present — clearing finalizers."
  kubectl patch gatewayclass eg -p '{"metadata":{"finalizers":null}}' --type=merge &>/dev/null || true
fi

# The EnvoyProxy has lived in ENVOY_GW_NAMESPACE since the parametersRef fix,
# but older runs put it in NAMESPACE_CLOUDBEES. Clean up both.
kubectl delete envoyproxy eg-aws-lb -n "${ENVOY_GW_NAMESPACE}" --ignore-not-found &>/dev/null || true
kubectl delete envoyproxy eg-aws-lb -n "${NAMESPACE_CLOUDBEES}" --ignore-not-found &>/dev/null || true
success "Gateway API resources removed."

# =============================================================================
# 3. ENVOY GATEWAY CONTROLLER
# =============================================================================
log "Uninstalling the Envoy Gateway Helm release..."
helm uninstall eg -n "${ENVOY_GW_NAMESPACE}" --wait --timeout 5m || true

log "Deleting namespace ${ENVOY_GW_NAMESPACE}..."
kubectl delete ns "${ENVOY_GW_NAMESPACE}" --ignore-not-found --timeout=300s \
  || warn "Namespace deletion timed out — inspect with: kubectl get all -n ${ENVOY_GW_NAMESPACE}"
success "Envoy Gateway uninstalled."

# =============================================================================
# 4. CRDs (opt-in)
# =============================================================================
if [[ "$DELETE_CRDS" == true ]]; then
  warn "Deleting Gateway API + Envoy Gateway CRDs cluster-wide..."
  kubectl delete crd -l gateway.envoyproxy.io/owning-gateway-namespace --ignore-not-found || true
  for crd in $(kubectl get crd -o name 2>/dev/null \
      | grep -E 'gateway\.networking\.k8s\.io|gateway\.envoyproxy\.io' || true); do
    log "  ${crd}"
    kubectl delete "$crd" --ignore-not-found || true
  done
  success "CRDs removed."
else
  log "Leaving CRDs in place (pass --delete-crds to remove them)."
fi

# =============================================================================
# 5. ACM CERTIFICATE (opt-in)
# =============================================================================
if [[ "$DELETE_CERT" == true ]]; then
  log "Looking up the ACM certificate for '${CJOC_HOST_NAME}'..."
  CERT_ARN=$(aws acm list-certificates --region "${AWS_REGION}" \
    --query "CertificateSummaryList[?DomainName=='${CJOC_HOST_NAME}'].CertificateArn | [0]" \
    --output text 2>/dev/null || true)

  if [[ -n "${CERT_ARN}" && "${CERT_ARN}" != "None" ]]; then
    # ACM refuses to delete a certificate still attached to a load balancer, so
    # this only succeeds once the ALB above (and the nginx NLB) are really gone.
    # Also removes the Route53 validation record the install script added.
    log "Deleting ${CERT_ARN}..."
    delete_acm_certificate "${CERT_ARN}" "${ROUTE53_ZONE_DOMAIN:-$(cut -d. -f2- <<< "${CJOC_HOST_NAME}")}"
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
$DELETE_CRDS || echo "  - Gateway API / Envoy Gateway CRDs"
$DELETE_CERT || echo "  - ACM certificate for ${CJOC_HOST_NAME}"
echo
echo "Route53 records for ${CJOC_HOST_NAME} are owned by external-dns; with"
echo "policy=sync it removes them once the Ingress is gone. Verify with:"
echo "  kubectl logs -n ${NAMESPACE_EXTERNAL_DNS:-kube-system} deploy/external-dns --tail=50"
