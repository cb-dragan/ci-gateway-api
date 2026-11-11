#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 05-installCloudBeesNginx.sh — Install CloudBees CI on EKS behind ingress-nginx
# (Ingress), the "before" state of the ingress-nginx -> Envoy Gateway migration
# demo. Run after 04-installNginx.sh. Teardown: 05-deleteCloudBees.sh
#
# THE RELEASE NAME IS DELIBERATE. It is "cloudbees-core-envoy", the same as in
# 05-installCloudBees.sh, so that script is the migration `helm upgrade` on this
# very release: it swaps the Ingress values for the Gateway values and nothing
# else. 05-deleteCloudBees.sh uses the same default name.
#
# Same Helm values as 05-installCloudBees.sh, except:
#   - OperationsCenter.Ingress.Class / tls / Annotations instead of Gateway.*
#   - an external-dns TTL of 60 s on the Ingress (short DNS cutover)
# The CasC block is the same too. With CASC_ENABLED=true, set in .env:
#   CASC_SCM_BUNDLE_PATH_CJOC=casc/cjoc-nginx
# The S3 logs, MCP and channel pinger toggles are refused here, so the upgrade
# diff to 05-installCloudBees.sh stays "ingress -> gateway" only.
# -----------------------------------------------------------------------------
set -euo pipefail

# Load environment variables
source ./.env

# Helper logging functions
log()     { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

INGRESS_CLASS_NAME=${INGRESS_CLASS_NAME:-nginx}

for toggle in S3_LOGS_ENABLED MCP_ENABLED CHANNEL_PINGER_ENABLED; do
  [[ "${!toggle:-false}" == "true" ]] \
    && error "${toggle}=true is not supported by this script. Set it to false for the migration demo."
done

# --- Optional: CasC bundle retriever (CASC_ENABLED=true) ---
CASC_ARGS=()
if [[ "${CASC_ENABLED:-false}" == "true" ]]; then
  # The gateway bundle (casc/cjoc) would provision controllers with Gateway
  # exposure while the cluster only has an Ingress controller.
  [[ "${CASC_SCM_BUNDLE_PATH_CJOC:-}" == *cjoc-nginx ]] \
    || error "CASC_SCM_BUNDLE_PATH_CJOC must point to the Ingress bundle (casc/cjoc-nginx), got '${CASC_SCM_BUNDLE_PATH_CJOC:-}'."

  log "Creating CasC secret and env var ConfigMap..."
  cat <<EOF | kubectl -n "${NAMESPACE_CLOUDBEES}" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: cjoc-secrets
type: Opaque
stringData:
  githubUser: ${CASC_SCM_USERNAME:?CASC_SCM_USERNAME is required when CASC_ENABLED=true}
  githubToken: ${CASC_SCM_PASSWORD:?CASC_SCM_PASSWORD is required when CASC_ENABLED=true}
  cjocLoginPassword: ${CJOC_ADMIN_PASSWORD:?CJOC_ADMIN_PASSWORD is required when CASC_ENABLED=true}
EOF

  # Env vars used for interpolation in the CasC bundle. Same keys and values as
  # 05-installCloudBees.sh, so the migration upgrade does not change this map.
  cat <<EOF | kubectl -n "${NAMESPACE_CLOUDBEES}" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cjoc-casc-envvars
data:
  ADMIN_ID: "${CJOC_ADMIN_USER}"
  ADMIN_NAME: "${CJOC_ADMIN_USER}"
  ADMIN_EMAIL: "${CJOC_ADMIN_EMAIL}"
  CJOC_VERSION: "latest"
  NAMESPACE: "${NAMESPACE_CLOUDBEES}"
  GATEWAY_NAME: "${GATEWAY_NAME}"
  GATEWAY_NAMESPACE: "${NAMESPACE_CLOUDBEES}"
  AGENT_VERSION: "latest"
  GATEWAY_DOMAIN: "${CJOC_HOST_NAME}"
  GATEWAY_PORT: "443"
  CASC_SCM_BRANCH: "${CASC_SCM_BRANCH}"
  CASC_SCM_REPO: "${CASC_SCM_REPO}"
  CONTROLLER_STORAGE_CLASS: "${CLOUDBEES_STORAGE_CLASS}"
EOF

  CASC_ARGS=(
    --set OperationsCenter.CasC.Enabled=true
    --set OperationsCenter.CasC.Retriever.Enabled=true
    --set OperationsCenter.CasC.Retriever.scmRepo="${CASC_SCM_REPO}"
    --set OperationsCenter.CasC.Retriever.scmBundlePath="${CASC_SCM_BUNDLE_PATH_CJOC}"
    --set OperationsCenter.CasC.Retriever.scmBranch="${CASC_SCM_BRANCH}"
    --set OperationsCenter.CasC.Retriever.scmPollingInterval="PT1M"
    --set OperationsCenter.CasC.Retriever.secrets.scmUsername="githubUser"
    --set OperationsCenter.CasC.Retriever.secrets.scmPassword="githubToken"
    --set OperationsCenter.ContainerEnvFrom[0].configMapRef.name="cjoc-casc-envvars"
    --set OperationsCenter.CasC.Retriever.secrets.secretName="cjoc-secrets"
    --set OperationsCenter.ExtraVolumes[0].name="cjoc-secrets"
    --set OperationsCenter.ExtraVolumes[0].secret.secretName="cjoc-secrets"
    --set OperationsCenter.ExtraVolumeMounts[0].name="cjoc-secrets"
    --set OperationsCenter.ExtraVolumeMounts[0].mountPath="/var/run/secrets/cjoc"
    --set OperationsCenter.ExtraVolumeMounts[0].readOnly=true
  )
  log "CasC bundle retriever enabled."
fi

HELM_DEBUG_ARGS=()
[[ "${HELM_DEBUG:-false}" == "true" ]] && HELM_DEBUG_ARGS=(--debug)

# --- Helm Deployment ---
log "Updating Helm repositories..."
helm repo add cloudbees https://charts.cloudbees.com/public/cloudbees || true
helm repo update

# TLS is off in the chart: it ends on the NLB (see 04-installNginx.sh), and the
# Ingress has no tls section. Protocol=https still tells CloudBees CI the public
# URL scheme.
log "Deploying CloudBees CI via Helm (Ingress class ${INGRESS_CLASS_NAME})..."
helm upgrade --install cloudbees-core-envoy cloudbees/cloudbees-core \
  --namespace "${NAMESPACE_CLOUDBEES}" \
  --set OperationsCenter.Ingress.Class="${INGRESS_CLASS_NAME}" \
  --set OperationsCenter.Ingress.tls.Enable=false \
  --set-json 'OperationsCenter.Ingress.Annotations={"external-dns.alpha.kubernetes.io/ttl":"60"}' \
  --set OperationsCenter.HostName="${CJOC_HOST_NAME}" \
  --set OperationsCenter.Protocol=https \
  --set OperationsCenter.NodeSelector.workload=controller \
  --set-json 'OperationsCenter.Tolerations=[{"key":"workload","operator":"Equal","value":"controller","effect":"NoSchedule"}]' \
  --set Master.HighAvailabilitySupport=true \
  --set Agents.SeparateNamespace.Enabled=true \
  --set Agents.SeparateNamespace.Create=true \
  --set Persistence.StorageClass="${CLOUDBEES_STORAGE_CLASS}" \
  --set Common.image.tag='latest' \
  ${CASC_ARGS[@]+"${CASC_ARGS[@]}"} \
  ${HELM_DEBUG_ARGS[@]+"${HELM_DEBUG_ARGS[@]}"}

# --- Wait for the Ingress address (the NLB hostname, published by nginx) ---
# Matched by host name, so the Ingress name does not have to be known.
log "Waiting for the Ingress address (this may take a few minutes)..."
INGRESS_ADDR=""
MAX_RETRIES=30
RETRY_COUNT=0

while [[ -z "$INGRESS_ADDR" && $RETRY_COUNT -lt $MAX_RETRIES ]]; do
    INGRESS_ADDR=$(kubectl get ingress -n "${NAMESPACE_CLOUDBEES}" \
      -o jsonpath="{.items[?(@.spec.rules[0].host=='${CJOC_HOST_NAME}')].status.loadBalancer.ingress[0].hostname}" \
      2>/dev/null || echo "")
    INGRESS_ADDR=${INGRESS_ADDR%% *}
    if [[ -z "$INGRESS_ADDR" ]]; then
        echo -n "."
        sleep 10
        RETRY_COUNT=$((RETRY_COUNT+1))
    fi
done

if [[ -n "$INGRESS_ADDR" ]]; then
    echo ""
    success "Ingress is ready!"
    log "NLB address: ${INGRESS_ADDR}"
    log "Operations Center URL: https://${CJOC_HOST_NAME}/cjoc/"
    log "Post-install: ./06-installExternalDNS.sh points ${CJOC_HOST_NAME} at ${INGRESS_ADDR}"
else
    echo ""
    error "Timed out waiting for the Ingress address. Check 'kubectl get ingress -n ${NAMESPACE_CLOUDBEES}' and the ingress-nginx Service."
fi

success "Installation completed successfully."
