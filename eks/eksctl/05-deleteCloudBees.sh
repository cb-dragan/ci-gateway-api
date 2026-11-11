#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 05-deleteCloudBees.sh — Uninstall CloudBees CI installed by
# 05-inatallCloudBees.sh.
#
# THE TWO THINGS `helm uninstall` DOES NOT DO
#
#   1. It does not delete PVCs created from StatefulSet volumeClaimTemplates.
#      Kubernetes retains them deliberately. jenkins-home-cjoc-0 and every
#      managed controller's volume survive — that is your JENKINS_HOME, so
#      deleting it is opt-in via --delete-data.
#
#   2. It does not touch managed controllers. CJOC creates those StatefulSets
#      at runtime, so Helm has no record of them. After `helm uninstall` they
#      keep running with no Operations Center to manage them, still burning
#      nodes and EBS. This script stops them by default but keeps their
#      volumes unless --delete-data is given: stop the compute, preserve the
#      data.
#
# MCP ROUTER (MCP_ENABLED=true in 05-installCloudBees.sh)
#   The router Deployment, Service, ServiceAccount, oauth-config ConfigMap and its
#   HTTPRoutes are all part of the Helm release, so `helm uninstall` removes them and
#   no extra step is needed. A user-created signing-key Secret (privateKeyJwt) is not
#   managed by the chart; delete it yourself if you made one.
#
# WHAT THIS DOES NOT DELETE
#   - The Gateway, GatewayClass, EnvoyProxy or the ALB. Those belong to
#     04-installEnvoy.sh — use 04-deleteEnvoy.sh.
#   - The efs-sc StorageClass or the EFS file system (02-*).
#   - external-dns (06-*).
#
# Usage:
#   ./05-deleteCloudBees.sh                    # remove CI, keep all volumes
#   ./05-deleteCloudBees.sh --delete-data      # also delete PVCs (JENKINS_HOME!)
#   ./05-deleteCloudBees.sh --delete-namespace # also delete the namespaces
#   ./05-deleteCloudBees.sh --keep-controllers # leave managed controllers running
#   ./05-deleteCloudBees.sh --yes              # skip the confirmation prompt
# -----------------------------------------------------------------------------
set -euo pipefail

source ./.env

log()     { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

RELEASE_NAME="${CLOUDBEES_RELEASE_NAME:-cloudbees-core-envoy}"
NS="${NAMESPACE_CLOUDBEES}"

DELETE_DATA=false
DELETE_NAMESPACE=false
KEEP_CONTROLLERS=false
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --delete-data)      DELETE_DATA=true ;;
    --delete-namespace) DELETE_NAMESPACE=true ;;
    --keep-controllers) KEEP_CONTROLLERS=true ;;
    --yes|-y)           ASSUME_YES=true ;;
    -h|--help)          sed -n '2,32p' "$0"; exit 0 ;;
    *)                  error "unknown flag '$1' (try --help)" ;;
  esac
  shift
done

# --delete-namespace without --delete-data is a trap: deleting the namespace
# deletes the PVCs in it regardless, so the "keep my data" promise would be
# silently broken.
if [[ "$DELETE_NAMESPACE" == true && "$DELETE_DATA" != true ]]; then
  error "--delete-namespace deletes the PVCs in it too. Pass --delete-data as well to confirm you mean it."
fi

for bin in kubectl helm jq; do
  command -v "$bin" >/dev/null 2>&1 || error "required tool '$bin' not found on PATH"
done

# =============================================================================
# 1. INVENTORY — show what exists before proposing to remove it
# =============================================================================
if ! kubectl get namespace "$NS" &>/dev/null; then
  log "Namespace '${NS}' does not exist. Nothing to do."
  exit 0
fi

RELEASE_PRESENT=false
helm status "$RELEASE_NAME" -n "$NS" &>/dev/null && RELEASE_PRESENT=true

# Managed controllers = StatefulSets and Deployments (HA controllers run as
# Deployments) in the namespace that Helm does not own. Identifying them by the
# absence of the Helm release annotation avoids relying on CloudBees-specific
# labels, which vary across chart versions. Listed as "kind/name".
MANAGED_CONTROLLERS=$(kubectl get statefulset,deployment -n "$NS" -o json 2>/dev/null \
  | jq -r --arg rel "$RELEASE_NAME" \
      '.items[] | select(.metadata.annotations["meta.helm.sh/release-name"] != $rel) | (.kind | ascii_downcase) + "/" + .metadata.name' \
  || true)

# Agents namespace, if Agents.SeparateNamespace.Create=true made one. Discovered
# rather than assumed, because the chart's default name has changed over time.
AGENT_NS=$(kubectl get namespace -o json 2>/dev/null \
  | jq -r --arg rel "$RELEASE_NAME" \
      '.items[] | select(.metadata.annotations["meta.helm.sh/release-name"] == $rel) | .metadata.name' \
  | grep -v "^${NS}$" || true)

PVCS=$(kubectl get pvc -n "$NS" --no-headers \
  -o custom-columns=NAME:.metadata.name,SIZE:.spec.resources.requests.storage,SC:.spec.storageClassName 2>/dev/null || true)

echo
echo "Cluster : $(kubectl config current-context 2>/dev/null || echo unknown)"
echo "Release : ${RELEASE_NAME} in ${NS} ($([[ "$RELEASE_PRESENT" == true ]] && echo present || echo 'NOT FOUND'))"
echo

if [[ -n "$MANAGED_CONTROLLERS" ]]; then
  echo "Managed controllers (created by CJOC, invisible to Helm):"
  while read -r c; do [[ -n "$c" ]] && echo "    - ${c}"; done <<< "$MANAGED_CONTROLLERS"
  echo
fi

if [[ -n "$PVCS" ]]; then
  echo "PersistentVolumeClaims in ${NS}:"
  while read -r line; do [[ -n "$line" ]] && echo "    ${line}"; done <<< "$PVCS"
  echo
fi

echo "Will delete:"
echo "    - Helm release ${RELEASE_NAME} (CJOC, HTTPRoute, RBAC, ConfigMaps; MCP Router and its routes if MCP_ENABLED was set)"
if [[ "$KEEP_CONTROLLERS" != true && -n "$MANAGED_CONTROLLERS" ]]; then
  echo "    - Managed controller StatefulSets and Deployments listed above (volumes kept)"
  echo "    - Their leftover Ingresses (label com.cloudbees.cje.type=master)"
fi
echo "    - Secret cjoc-secrets and ConfigMap cjoc-casc-envvars (made by the install script, outside Helm)"
$DELETE_DATA      && echo "    - ALL PVCs above — THIS DESTROYS JENKINS_HOME AND EVERY BUILD HISTORY"
$DELETE_NAMESPACE && echo "    - Namespace ${NS}${AGENT_NS:+ and ${AGENT_NS}}"
echo
echo "Will keep:"
$DELETE_DATA      || echo "    - All PVCs / JENKINS_HOME data"
$DELETE_NAMESPACE || echo "    - Namespace ${NS}"
$KEEP_CONTROLLERS && echo "    - Managed controllers (running, with no CJOC to manage them)"
echo "    - Gateway / ALB (use 04-deleteEnvoy.sh), StorageClass, EFS, external-dns"
echo

if [[ "$DELETE_DATA" == true ]]; then
  warn "--delete-data is set. JENKINS_HOME, job configuration and build history will be gone."
  warn "The EFS-backed PVs use reclaimPolicy: Delete, so the underlying data goes too."
fi

if [[ "$ASSUME_YES" != true ]]; then
  if [[ "$DELETE_DATA" == true ]]; then
    read -r -p "Type the namespace name '${NS}' to confirm data deletion: " reply
    [[ "$reply" == "$NS" ]] || { log "Aborted."; exit 0; }
  else
    read -r -p "Proceed? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }
  fi
fi

# =============================================================================
# 2. MANAGED CONTROLLERS — stop them before removing the thing that manages them
# =============================================================================
if [[ "$KEEP_CONTROLLERS" != true && -n "$MANAGED_CONTROLLERS" ]]; then
  log "Deleting managed controller StatefulSets and Deployments (PVCs are retained)..."
  while read -r c; do
    [[ -z "$c" ]] && continue
    log "  ${c}"
    # --cascade=foreground so pods are gone before we move on; otherwise the
    # namespace delete below can race with terminating agent pods.
    kubectl delete "$c" -n "$NS" --cascade=foreground --timeout=300s \
      --ignore-not-found || warn "  could not fully delete ${c}"
  done <<< "$MANAGED_CONTROLLERS"
  success "Managed controllers stopped."
elif [[ -n "$MANAGED_CONTROLLERS" ]]; then
  warn "Leaving managed controllers running as requested (--keep-controllers)."
fi

# =============================================================================
# 3. HELM RELEASE
# =============================================================================
if [[ "$RELEASE_PRESENT" == true ]]; then
  log "Uninstalling Helm release ${RELEASE_NAME}..."
  helm uninstall "$RELEASE_NAME" -n "$NS" --wait --timeout 10m \
    || warn "helm uninstall reported an error — continuing with cleanup."
  success "Helm release removed."
else
  log "Helm release '${RELEASE_NAME}' not found in ${NS}; skipping."
fi

# Chart-managed HTTPRoutes should go with the release. Sweep any that outlived
# it (a failed uninstall can leave them, and a stale HTTPRoute keeps routing).
for route in $(kubectl get httproute -n "$NS" -o name 2>/dev/null || true); do
  warn "Removing leftover ${route}"
  kubectl delete "$route" -n "$NS" --ignore-not-found || true
done

# With ingress-nginx, CJOC creates an Ingress per managed controller (not Helm).
if [[ "$KEEP_CONTROLLERS" != true ]]; then
  for ing in $(kubectl get ingress -n "$NS" -l com.cloudbees.cje.type=master -o name 2>/dev/null || true); do
    warn "Removing leftover ${ing}"
    kubectl delete "$ing" -n "$NS" --ignore-not-found || true
  done
fi

# Made by 05-installCloudBees*.sh with kubectl, so helm uninstall leaves them.
# The Secret holds the CasC SCM token and the CJOC admin password.
kubectl delete secret/cjoc-secrets configmap/cjoc-casc-envvars -n "$NS" --ignore-not-found || true

# =============================================================================
# 4. PVCs (opt-in)
# =============================================================================
if [[ "$DELETE_DATA" == true ]]; then
  log "Deleting PVCs in ${NS}..."
  kubectl delete pvc --all -n "$NS" --timeout=300s \
    || warn "some PVCs did not delete — a pod may still have them mounted."

  if [[ -n "$AGENT_NS" ]] && kubectl get namespace "$AGENT_NS" &>/dev/null; then
    log "Deleting PVCs in ${AGENT_NS}..."
    kubectl delete pvc --all -n "$AGENT_NS" --timeout=300s || true
  fi
  success "PVCs deleted."
else
  log "Keeping all PVCs. Reinstalling with the same release name reattaches them."
fi

# =============================================================================
# 5. NAMESPACES (opt-in)
# =============================================================================
if [[ "$DELETE_NAMESPACE" == true ]]; then
  if [[ -n "$AGENT_NS" ]]; then
    log "Deleting agents namespace ${AGENT_NS}..."
    kubectl delete namespace "$AGENT_NS" --ignore-not-found --timeout=300s || true
  fi
  log "Deleting namespace ${NS}..."
  kubectl delete namespace "$NS" --ignore-not-found --timeout=300s \
    || warn "namespace deletion timed out — check for finalizers: kubectl get all -n ${NS}"
  success "Namespaces deleted."
else
  log "Keeping namespace ${NS}."
fi

# =============================================================================
# 6. SUMMARY
# =============================================================================
echo
success "Uninstall complete."
echo

if [[ "$DELETE_DATA" != true ]]; then
  REMAINING=$(kubectl get pvc -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$REMAINING" != "0" ]]; then
    echo "  ${REMAINING} PVC(s) retained in ${NS}. They still cost money:"
    echo "    kubectl get pvc -n ${NS}"
    echo "  Reinstall with 05-inatallCloudBees.sh to reattach, or drop them with:"
    echo "    ./05-deleteCloudBees.sh --delete-data"
    echo
  fi
fi

echo "Still present by design — remove separately if you want them gone:"
echo "    Gateway / ALB     : ./04-deleteEnvoy.sh"
echo "    external-dns      : helm uninstall external-dns -n ${NAMESPACE_EXTERNAL_DNS:-kube-system}"
echo "    EFS + StorageClass: ./02-delete-efs-filesystem.sh"
