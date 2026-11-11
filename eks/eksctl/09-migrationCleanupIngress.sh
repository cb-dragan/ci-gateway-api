#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 09-migrationCleanupIngress.sh — Remove leftover managed-controller Ingresses
# after the ingress-nginx -> Envoy Gateway migration. Runbook:
# README-NGINX-TO-ENVOY.md
#
# WHY. CJOC creates a managed controller's Ingress when it provisions the
# controller, so the Helm upgrade does not remove it, and reprovisioning a
# controller creates an HTTPRoute but leaves the old Ingress. Only the CJOC
# Ingress is removed by Helm.
#
# SAFETY
#   - Only Ingresses with label com.cloudbees.cje.type=master AND class nginx.
#   - Only for migrated controllers: the Ingress needs an HTTPRoute with the
#     same name and label in the namespace. ASSUMPTION: the route is named like
#     the Ingress; check the list below. --all skips this check.
#   - The Ingresses are saved to ingress-backup-<timestamp>.yaml first (local
#     file, do not commit it), then deleted after confirmation.
#
# After this, remove ingress-nginx itself with ./04-deleteNginx.sh.
#
# Usage:
#   ./09-migrationCleanupIngress.sh          # migrated controllers only
#   ./09-migrationCleanupIngress.sh --all    # every matching Ingress
#   ./09-migrationCleanupIngress.sh --yes    # skip the confirmation prompt
# -----------------------------------------------------------------------------
set -euo pipefail

source ./.env

log()     { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

ALL=false
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)     ALL=true ;;
    --yes|-y)  ASSUME_YES=true ;;
    -h|--help) awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *)         error "unknown flag '$1' (try --help)" ;;
  esac
  shift
done

NS="${NAMESPACE_CLOUDBEES}"
INGRESS_CLASS_NAME=${INGRESS_CLASS_NAME:-nginx}
MC_LABEL="com.cloudbees.cje.type=master"   # legacy term, kept by CloudBees in labels

for bin in kubectl jq; do
  command -v "$bin" >/dev/null 2>&1 || error "required tool '$bin' not found on PATH"
done

# =============================================================================
# 1. INVENTORY
# =============================================================================
INGRESSES=$(kubectl get ingress -n "${NS}" -l "${MC_LABEL}" -o json \
  | jq -r --arg c "${INGRESS_CLASS_NAME}" '.items[] | select((.spec.ingressClassName // "") == $c) | .metadata.name')
[[ -n "${INGRESSES}" ]] || { log "No '${INGRESS_CLASS_NAME}' Ingresses with label ${MC_LABEL} in ${NS}. Nothing to do."; exit 0; }

ROUTES=$(kubectl get httproute -n "${NS}" -l "${MC_LABEL}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
  || error "Cannot list HTTPRoutes (Gateway API CRDs missing?). Has the migration run?")

TARGETS=()
echo
echo "Managed controller Ingresses in ${NS} (class ${INGRESS_CLASS_NAME}):"
while read -r name; do
  [[ -z "${name}" ]] && continue
  if [[ "${ALL}" == true || " ${ROUTES} " == *" ${name} "* ]]; then
    echo "    - ${name}  -> delete"
    TARGETS+=("${name}")
  else
    echo "    - ${name}  -> KEEP (no HTTPRoute named ${name}; reprovision the controller first)"
  fi
done <<< "${INGRESSES}"
echo

[[ ${#TARGETS[@]} -gt 0 ]] || { warn "No migrated controllers found. Nothing deleted."; exit 0; }

# =============================================================================
# 2. BACKUP, CONFIRM, DELETE
# =============================================================================
BACKUP="ingress-backup-$(date +%Y%m%d-%H%M%S).yaml"
kubectl get ingress "${TARGETS[@]}" -n "${NS}" -o yaml > "${BACKUP}"
success "Backup written: ${BACKUP} (local only, do not commit)"

if [[ "${ASSUME_YES}" != true ]]; then
  read -r -p "Delete ${#TARGETS[@]} Ingress(es) from ${NS}? [y/N] " reply
  [[ "${reply}" =~ ^[Yy]$ ]] || { log "Aborted. The backup file is kept."; exit 0; }
fi

kubectl delete ingress "${TARGETS[@]}" -n "${NS}"
success "Deleted ${#TARGETS[@]} Ingress(es)."

echo
echo "Next:"
echo "  - Check DNS now points to the ALB:  dig +short ${CJOC_HOST_NAME}"
echo "  - Remove ingress-nginx and the NLB: ./04-deleteNginx.sh"
echo "  - Restore the DNS TTL you lowered before the migration."
