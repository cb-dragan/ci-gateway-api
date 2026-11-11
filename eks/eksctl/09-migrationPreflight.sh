#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 09-migrationPreflight.sh — Read-only checks before the ingress-nginx -> Envoy
# Gateway migration. Mirrors the prerequisites of the CloudBees guide "Migrate
# from Ingress to Gateway API". Changes nothing in the cluster. Safe to run
# before and after 04-installEnvoy.sh. Runbook: README-NGINX-TO-ENVOY.md
#
# Checks: ingress-nginx present, CJOC Ingress class, managed controllers and
# their Ingresses, NGINX annotations that do not migrate, Gateway Programmed and
# attachedRoutes, CloudBees chart version (no upgrade during the migration),
# external-dns sources, DNS TTL, backup reminder.
#
# Exit code: 1 if a blocking check failed, 0 otherwise (warnings are advice).
#
# Usage: ./09-migrationPreflight.sh
# -----------------------------------------------------------------------------
set -euo pipefail

source ./.env

log()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; WARNINGS=$((WARNINGS+1)); }
fail() { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$*"; FAILURES=$((FAILURES+1)); }
WARNINGS=0
FAILURES=0

NS="${NAMESPACE_CLOUDBEES}"
RELEASE_NAME="${CLOUDBEES_RELEASE_NAME:-cloudbees-core-envoy}"
INGRESS_NGINX_NAMESPACE=${INGRESS_NGINX_NAMESPACE:-ingress-nginx}
INGRESS_CLASS_NAME=${INGRESS_CLASS_NAME:-nginx}
MC_LABEL="com.cloudbees.cje.type=master"   # legacy term, kept by CloudBees in labels

for bin in kubectl helm jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "required tool '$bin' not found on PATH" >&2; exit 1; }
done

echo
log "Cluster: $(kubectl config current-context 2>/dev/null || echo unknown) | namespace: ${NS} | host: ${CJOC_HOST_NAME}"
echo

# 1. ingress-nginx ------------------------------------------------------------
if kubectl get deployment ingress-nginx-controller -n "${INGRESS_NGINX_NAMESPACE}" &>/dev/null; then
  CHART=$(helm list -n "${INGRESS_NGINX_NAMESPACE}" -f '^ingress-nginx$' -o json 2>/dev/null | jq -r '.[0].chart // "chart unknown"')
  ok "ingress-nginx is present (${CHART}). The project is retired: no more security fixes."
else
  fail "ingress-nginx controller not found in ${INGRESS_NGINX_NAMESPACE}. Nothing to migrate from?"
fi

# 2. CJOC Ingress -------------------------------------------------------------
CJOC_ING=$(kubectl get ingress -n "${NS}" -o json 2>/dev/null | jq -r --arg h "${CJOC_HOST_NAME}" '
  .items[] | select(any(.spec.rules[]?; .host == $h and any(.http.paths[]?; (.path // "") | startswith("/cjoc"))))
  | "\(.metadata.name) (class: \(.spec.ingressClassName // .metadata.annotations["kubernetes.io/ingress.class"] // "none"))"')
if [[ -n "${CJOC_ING}" ]]; then
  ok "CJOC Ingress: ${CJOC_ING}"
  [[ "${CJOC_ING}" == *"class: ${INGRESS_CLASS_NAME})"* ]] || warn "CJOC Ingress class is not '${INGRESS_CLASS_NAME}'."
elif [[ -n "$(kubectl get httproute -n "${NS}" -o name 2>/dev/null)" ]]; then
  warn "No CJOC Ingress, but HTTPRoutes exist: the Helm upgrade has probably run already."
else
  fail "No Ingress for host ${CJOC_HOST_NAME} and path /cjoc in ${NS}. Is CloudBees CI installed?"
fi

# 3. Managed controllers and their Ingresses ----------------------------------
MC_LIST=$(kubectl get statefulset -n "${NS}" -l "${MC_LABEL}" -o name 2>/dev/null | sed 's#.*/##' | paste -sd, - || true)
MC_ING=$(kubectl get ingress -n "${NS}" -l "${MC_LABEL}" -o name 2>/dev/null | sed 's#.*/##' | paste -sd, - || true)
log "Managed controllers (label ${MC_LABEL}): ${MC_LIST:-none}"
log "Managed controller Ingresses: ${MC_ING:-none}"
[[ -n "${MC_ING}" ]] && warn "Each controller needs drain + reprovision. Their Ingresses are NOT removed by Helm: use 09-migrationCleanupIngress.sh afterwards."

# 4. NGINX annotations that do not migrate ------------------------------------
ANNOT=$(kubectl get ingress -n "${NS}" -o json 2>/dev/null | jq -r '
  .items[] | .metadata.name as $n | (.metadata.annotations // {}) | to_entries[]
  | select(.key | startswith("nginx.ingress.kubernetes.io/")) | "\($n)\t\(.key)\t\(.value)"' || true)
if [[ -n "${ANNOT}" ]]; then
  warn "NGINX annotations are not migrated. Re-implement what you rely on with Gateway policies:"
  echo "${ANNOT}" | awk -F'\t' '{printf "          %-28s %-52s %s\n", $1, $2, $3}'
  if [[ "${ANNOT}" =~ (proxy-body-size|timeout|request-buffering) ]]; then
    warn "Body size / timeouts / buffering found. 04-installEnvoy.sh only sets a ClientTrafficPolicy (escaped slashes, XFF hops) and a 4000 s ALB idle timeout."
  fi
else
  ok "No nginx.ingress.kubernetes.io annotations on Ingresses in ${NS}."
fi

# 5. Gateway ------------------------------------------------------------------
GW="gateways.gateway.networking.k8s.io"
if kubectl get "${GW}" "${GATEWAY_NAME}" -n "${NS}" &>/dev/null; then
  PROGRAMMED=$(kubectl get "${GW}" "${GATEWAY_NAME}" -n "${NS}" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')
  [[ "${PROGRAMMED}" == "True" ]] && ok "Gateway ${GATEWAY_NAME} is Programmed." || fail "Gateway ${GATEWAY_NAME} is not Programmed (got '${PROGRAMMED:-unknown}')."
  log "attachedRoutes per listener: $(kubectl get "${GW}" "${GATEWAY_NAME}" -n "${NS}" -o jsonpath='{.status.listeners[*].attachedRoutes}') (0 is normal before the Helm upgrade)"
else
  warn "Gateway ${GATEWAY_NAME} not found in ${NS}. Run ./04-installEnvoy.sh before the Helm upgrade."
fi
LABEL=$(kubectl get namespace "${NS}" -o jsonpath='{.metadata.labels.cloudbees\.com/gateway-routes}' 2>/dev/null || true)
[[ "${LABEL}" == "enabled" ]] && ok "Namespace ${NS} has cloudbees.com/gateway-routes=enabled." \
  || warn "Namespace ${NS} lacks the label cloudbees.com/gateway-routes=enabled (04-installEnvoy.sh sets it)."

# 6. CloudBees chart version --------------------------------------------------
# The migration must not be combined with a version upgrade.
CUR=$(helm list -n "${NS}" -f "^${RELEASE_NAME}\$" -o json 2>/dev/null | jq -r '.[0].chart // empty')
helm repo update cloudbees >/dev/null 2>&1 || warn "Could not refresh the cloudbees Helm repo; the latest version below may be stale."
LATEST=$(helm search repo cloudbees/cloudbees-core -o json 2>/dev/null | jq -r '.[0].version // empty')
if [[ -z "${CUR}" ]]; then
  fail "Helm release ${RELEASE_NAME} not found in ${NS}."
elif [[ -n "${LATEST}" && "${CUR}" != "cloudbees-core-${LATEST}" ]]; then
  warn "Deployed chart ${CUR}, latest cloudbees-core-${LATEST}. Do NOT upgrade during the migration; the helm upgrade in 05-installCloudBees.sh uses the latest chart."
else
  ok "Deployed chart ${CUR} is the latest."
fi
warn "05-installCloudBees.sh sets Common.image.tag=latest (mutable). Restarted pods may run a newer CloudBees CI. Running CJOC image: $(kubectl get statefulset cjoc -n "${NS}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo unknown)"

# 7. external-dns -------------------------------------------------------------
SOURCES=$(helm get values external-dns -n "${NAMESPACE_EXTERNAL_DNS:-external-dns}" -o json 2>/dev/null | jq -r '(.sources // []) | join(",")' || true)
if [[ "${SOURCES}" == *ingress* ]]; then
  ok "external-dns sources: ${SOURCES}. It reads the NLB from the nginx Ingress and the ALB from the Envoy Ingress cjoc-alb."
  warn "Both claim ${CJOC_HOST_NAME} until the leftover controller Ingresses are removed. The record may flap or stay on the NLB."
else
  warn "external-dns sources: '${SOURCES:-not installed}'. The ALB record is created from the Ingress source (06-installExternalDNS.sh)."
fi

# 8. DNS TTL ------------------------------------------------------------------
if command -v dig >/dev/null 2>&1; then
  TTL=$(dig +noall +answer "${CJOC_HOST_NAME}" | awk 'NR==1 {print $2}')
  if [[ -z "${TTL}" ]]; then warn "${CJOC_HOST_NAME} does not resolve from here."
  elif (( TTL > 60 )); then warn "DNS TTL seen by your resolver is ${TTL} s. CloudBees advises 60 s, lowered at least 24 h before the window."
  else ok "DNS TTL seen by your resolver is ${TTL} s."; fi
else
  warn "dig not found: check the DNS TTL by hand (60 s advised, lowered at least 24 h before)."
fi

# 9. Reminders ----------------------------------------------------------------
warn "Back up the operations center and managed controller configuration first (CloudBees backup docs)."
warn "Plan a window that covers drain, deprovision and provision of every controller."

echo
log "Result: ${FAILURES} failure(s), ${WARNINGS} warning(s)."
[[ "${FAILURES}" -eq 0 ]]
