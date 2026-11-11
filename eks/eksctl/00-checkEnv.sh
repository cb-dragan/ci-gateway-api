#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 00-checkEnv.sh — Read-only checks before creating a new cluster. Run it after
# filling .env and before 01-createCluster.sh. Changes nothing, and never prints
# secret values (only whether they are set).
#
# Checks: tools, .env variables (set, no <PLACEHOLDER>, exported where envsubst
# needs them), name rules, AWS account, Route53 zone for CJOC_HOST_NAME, an
# existing cluster with the same name, kubeconfig isolation, a stale node pool
# state file.
#
# Exit code: 1 if a blocking check failed, 0 otherwise (warnings are advice).
#
# Usage: ./00-checkEnv.sh [env-file]      # default ./.env
# -----------------------------------------------------------------------------
set -eo pipefail

ENV_FILE="${1:-./.env}"
ok()   { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; WARNINGS=$((WARNINGS+1)); }
fail() { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$*"; FAILURES=$((FAILURES+1)); }
WARNINGS=0
FAILURES=0

[[ -f "${ENV_FILE}" ]] || { echo "[FAIL] ${ENV_FILE} not found. Create it: cp .env-template .env" >&2; exit 1; }
# Look at the text first: an unquoted <PLACEHOLDER> is a shell redirect and breaks `source`.
PLACEHOLDERS=$(grep -nE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=.*<[A-Za-z_ -]+>' "${ENV_FILE}" | cut -d: -f1 | paste -sd, - || true)
[[ -z "${PLACEHOLDERS}" ]] || fail "${ENV_FILE} still has <PLACEHOLDER> values on line(s): ${PLACEHOLDERS}"
if ! bash -n "${ENV_FILE}" 2>/dev/null; then
  fail "${ENV_FILE} has a shell syntax error (check with: bash -n ${ENV_FILE})"
  echo "Result: ${FAILURES} failure(s)."; exit 1
fi
# Errexit off: a line with an unquoted <...> fails on its own, and its variable then shows as unset below.
set +e; source "${ENV_FILE}" 2>/dev/null; set -e

# Needed by the install path (nginx before state, then Envoy). No default in the scripts.
REQUIRED=(AWS_DEFAULT_REGION CLUSTER_NAME TAG_CB_USER TAG_CB_OWNER TAG_CB_ENVIRONMENT
  CJOC_HOST_NAME NAMESPACE_CLOUDBEES GATEWAY_NAME CLOUDBEES_STORAGE_CLASS
  ENVOY_GATEWAY_VERSION ENVOY_GW_NAMESPACE HELM_VERSION_FLAG
  EXTERNAL_DNS_CHART_VERSION EXTERNAL_DNS_POLICY_NAME EXTERNAL_DNS_ROLE_NAME
  NAMESPACE_EXTERNAL_DNS SERVICE_ACCOUNT_NAME)
# Only with CASC_ENABLED=true.
CASC_REQUIRED=(CASC_SCM_REPO CASC_SCM_BRANCH CASC_SCM_BUNDLE_PATH_CJOC CASC_SCM_USERNAME
  CASC_SCM_PASSWORD CJOC_ADMIN_USER CJOC_ADMIN_EMAIL CJOC_ADMIN_PASSWORD)
# 01-createCluster.sh renders eksctl-config.yaml.tpl with envsubst, which only sees exported variables.
EXPORTED=(AWS_DEFAULT_REGION CLUSTER_NAME TAG_CB_USER TAG_CB_OWNER TAG_CB_ENVIRONMENT)
# Safe to show.
SHOW=(AWS_DEFAULT_REGION CLUSTER_NAME CJOC_HOST_NAME NAMESPACE_CLOUDBEES CLOUDBEES_STORAGE_CLASS)

check_var() {  # name
  local v="${!1:-}"
  if [[ -z "$v" ]]; then fail "$1 is not set in ${ENV_FILE}"
  elif [[ "$v" == *"<"*">"* ]]; then fail "$1 still contains a <PLACEHOLDER>"
  else return 0; fi
  return 1
}

echo; echo "== Tools"
for t in aws eksctl kubectl helm jq envsubst; do
  command -v "$t" >/dev/null 2>&1 && ok "$t found" || fail "$t not found on PATH"
done
command -v dig >/dev/null 2>&1 || warn "dig not found (used by 09-migrationPreflight.sh)"
(( BASH_VERSINFO[0] >= 4 )) || warn "bash ${BASH_VERSION} is older than 4: 02-create-efs-filesystem.sh and 06-installExternalDNS.sh need bash 4+"

echo; echo "== .env variables (${ENV_FILE})"
for v in "${REQUIRED[@]}"; do check_var "$v" && :; done
for v in "${SHOW[@]}"; do [[ -n "${!v:-}" ]] && echo "         ${v}=${!v}"; done
if [[ "${CASC_ENABLED:-false}" == "true" ]]; then
  for v in "${CASC_REQUIRED[@]}"; do check_var "$v" && :; done
  [[ "${CASC_SCM_BUNDLE_PATH_CJOC:-}" == *cjoc-nginx ]] \
    && ok "CasC bundle path is the Ingress (before) bundle" \
    || warn "CASC_SCM_BUNDLE_PATH_CJOC='${CASC_SCM_BUNDLE_PATH_CJOC:-}': 05-installCloudBeesNginx.sh needs casc/cjoc-nginx (casc/cjoc is for the migrated state)"
else
  ok "CASC_ENABLED is not true: CasC variables not required"
fi
for v in "${EXPORTED[@]}"; do
  [[ "$(declare -p "$v" 2>/dev/null)" =~ ^declare\ -[a-zA-Z]*x ]] || fail "$v is set but not exported (add 'export'): envsubst would render it empty"
done
for v in S3_LOGS_ENABLED MCP_ENABLED CHANNEL_PINGER_ENABLED; do
  [[ "${!v:-false}" == "true" ]] && warn "$v=true: 05-installCloudBeesNginx.sh (before state) refuses it"
done

echo; echo "== Rules"
[[ "${AWS_DEFAULT_REGION:-}" == "us-east-1" ]] && ok "region is us-east-1" \
  || fail "AWS_DEFAULT_REGION='${AWS_DEFAULT_REGION:-}' but eksctl-config.yaml.tpl pins the zones us-east-1a/us-east-1b"
[[ "${CLUSTER_NAME:-x}" =~ ^[a-z][a-z0-9-]*$ ]] && ok "CLUSTER_NAME format" \
  || fail "CLUSTER_NAME must be lowercase letters, digits, '-' and start with a letter (it is part of S3 bucket and IAM names)"
(( ${#CLUSTER_NAME} <= 14 )) || warn "CLUSTER_NAME is ${#CLUSTER_NAME} chars; the EC2 add-on target group name '<name>-ec2-controller-tg' is limited to 32"
[[ "${CJOC_HOST_NAME:-}" =~ ^[a-z0-9-]+(\.[a-z0-9-]+){2,}$ ]] && ok "CJOC_HOST_NAME format" \
  || fail "CJOC_HOST_NAME must be a lowercase host name with at least 3 labels"

echo; echo "== AWS (read-only calls)"
if IDENTITY=$(aws sts get-caller-identity --query '[Account,Arn]' --output text 2>/dev/null); then
  ok "AWS identity: ${IDENTITY} (profile: ${AWS_PROFILE:-none})"
  ZONE_DOMAIN="${ROUTE53_ZONE_DOMAIN:-$(cut -d. -f2- <<< "${CJOC_HOST_NAME:-.}")}"
  ZID=$(aws route53 list-hosted-zones-by-name --dns-name "${ZONE_DOMAIN}." \
    --query "HostedZones[?Name=='${ZONE_DOMAIN}.' && Config.PrivateZone==\`false\`].Id | [0]" --output text 2>/dev/null || true)
  [[ -n "$ZID" && "$ZID" != "None" ]] && ok "public Route53 zone for ${ZONE_DOMAIN} found" \
    || fail "no public Route53 zone for '${ZONE_DOMAIN}' (ACM validation and external-dns need it; or set ROUTE53_ZONE_DOMAIN)"
  aws eks describe-cluster --name "${CLUSTER_NAME:-x}" --region "${AWS_DEFAULT_REGION:-us-east-1}" >/dev/null 2>&1 \
    && warn "an EKS cluster named '${CLUSTER_NAME}' already exists in this account/region" \
    || ok "no existing cluster named '${CLUSTER_NAME:-}'"
else
  fail "aws sts get-caller-identity failed: log in first (aws sso login --profile ...), see 00-login.sh"
fi

echo; echo "== Local state"
if [[ -n "${KUBECONFIG:-}" ]]; then ok "KUBECONFIG is set: kubectl will use ${KUBECONFIG}"
else warn "KUBECONFIG is not set: 01-createCluster.sh writes into ~/.kube/config and later scripts use whatever context is current. Suggested: KUBECONFIG=\"\$PWD/kubecfg-\${CLUSTER_NAME}\" (git-ignored)"; fi
ls .nodepool-scale-state.json* >/dev/null 2>&1 \
  && warn ".nodepool-scale-state.json* exists: 01-scaleUpNodePools.sh would apply those sizes to the new cluster. Delete it before creating a new cluster."

echo; echo "Result: ${FAILURES} failure(s), ${WARNINGS} warning(s)."
[[ "${FAILURES}" -eq 0 ]]
