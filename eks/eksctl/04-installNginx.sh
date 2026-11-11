#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 04-installNginx.sh — Install community ingress-nginx behind a public NLB on
# EKS. TLS terminates on the NLB (ACM cert); nginx only speaks plain HTTP.
# Teardown: 04-deleteNginx.sh
#
# This is the "before" state of the ingress-nginx -> Envoy Gateway migration
# demo (see README-NGINX-TO-ENVOY.md). The community ingress-nginx project is
# retired (no more security fixes): demo use only.
#
# Topology: Internet -> NLB (TLS 443 + ACM cert, 80 -> redirect) -> ingress-nginx
# (plain HTTP) -> Ingress -> CJOC.
#
# The ACM cert block below is the same as in 04-installEnvoy.sh. The cert is
# looked up by hostname, so the later Envoy step reuses it (no second wait).
# -----------------------------------------------------------------------------
set -euo pipefail

# Load environment variables
source ./.env

# Helper logging functions
log()     { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

AWS_REGION=${AWS_DEFAULT_REGION:-us-east-1}
INGRESS_NGINX_NAMESPACE=${INGRESS_NGINX_NAMESPACE:-ingress-nginx}
INGRESS_CLASS_NAME=${INGRESS_CLASS_NAME:-nginx}
# Newest chart in the upstream index when this was written (app 1.15.0, 2026-03).
INGRESS_NGINX_CHART_VERSION=${INGRESS_NGINX_CHART_VERSION:-4.15.1}

for bin in aws kubectl helm; do
  command -v "$bin" >/dev/null 2>&1 || error "required tool '$bin' not found on PATH"
done

# Without the AWS Load Balancer Controller the Service never gets an NLB.
kubectl get deployment aws-load-balancer-controller -n kube-system >/dev/null 2>&1 \
  || error "AWS Load Balancer Controller not found - run ./03-installAwsLbController.sh first"

# --- Create Kubernetes Namespace for CJOC ---
log "Configuring namespace ${NAMESPACE_CLOUDBEES}..."
kubectl create namespace "${NAMESPACE_CLOUDBEES}" --dry-run=client -o yaml | kubectl apply -f -

# --- AWS ACM Certificate Management ---
# The certificate is attached to the NLB TLS listener (annotation on the nginx
# Service below). TLS terminates at the NLB; nginx speaks plain HTTP behind it.
if [[ -z "${ACM_CERT_ARN:-}" ]]; then
  # Filter on ISSUED. Without this, a stale PENDING_VALIDATION or FAILED cert
  # from an earlier run gets silently reused and the listener comes up bare.
  log "Checking for an ISSUED ACM certificate for '${CJOC_HOST_NAME}' in '${AWS_REGION}'..."
  ACM_CERT_ARN=$(aws acm list-certificates --region "${AWS_REGION}" \
    --certificate-statuses ISSUED \
    --query "CertificateSummaryList[?DomainName=='${CJOC_HOST_NAME}'].CertificateArn | [0]" --output text 2>/dev/null || true)

  if [[ -z "${ACM_CERT_ARN}" || "${ACM_CERT_ARN}" == "None" ]]; then
    log "No issued certificate found. Requesting an Amazon-issued ACM certificate..."
    ACM_CERT_ARN=$(aws acm request-certificate --region "${AWS_REGION}" \
      --domain-name "${CJOC_HOST_NAME}" \
      --validation-method DNS \
      --tags Key=Name,Value="${CJOC_HOST_NAME}-acm-cert" Key=cb-user,Value="${TAG_CB_USER:-acaternberg}" Key=cb-owner,Value="${TAG_CB_OWNER:-professional-services}" Key=cb-environment,Value="${TAG_CB_ENVIRONMENT:-demo}" \
      --query "CertificateArn" --output text)
    success "Requested certificate: ${ACM_CERT_ARN}"

    # ACM populates ResourceRecord asynchronously; poll until it appears.
    log "Waiting for ACM to publish the DNS validation record..."
    VALIDATION_NAME=""; VALIDATION_VALUE=""
    for _ in $(seq 1 30); do
      read -r VALIDATION_NAME VALIDATION_VALUE < <(aws acm describe-certificate \
        --region "${AWS_REGION}" --certificate-arn "${ACM_CERT_ARN}" \
        --query "Certificate.DomainValidationOptions[0].ResourceRecord.[Name,Value]" \
        --output text 2>/dev/null || echo "")
      [[ -n "${VALIDATION_NAME}" && "${VALIDATION_NAME}" != "None" ]] && break
      sleep 5
    done
    [[ -n "${VALIDATION_NAME}" && "${VALIDATION_NAME}" != "None" ]] \
      || error "ACM never returned a validation record for ${ACM_CERT_ARN}"

    ROUTE53_ZONE_DOMAIN="${ROUTE53_ZONE_DOMAIN:-$(cut -d. -f2- <<< "${CJOC_HOST_NAME}")}"
    log "Resolving hosted zone for '${ROUTE53_ZONE_DOMAIN}'..."
    HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
      --dns-name "${ROUTE53_ZONE_DOMAIN}." \
      --query "HostedZones[?Name=='${ROUTE53_ZONE_DOMAIN}.'].Id | [0]" \
      --output text | sed 's#/hostedzone/##')
    [[ -n "${HOSTED_ZONE_ID}" && "${HOSTED_ZONE_ID}" != "None" ]] \
      || error "no public hosted zone for '${ROUTE53_ZONE_DOMAIN}' - create it, or set ROUTE53_ZONE_DOMAIN in .env"

    log "Upserting validation CNAME ${VALIDATION_NAME} into zone ${HOSTED_ZONE_ID}..."
    aws route53 change-resource-record-sets --hosted-zone-id "${HOSTED_ZONE_ID}" \
      --change-batch "{
        \"Changes\": [{
          \"Action\": \"UPSERT\",
          \"ResourceRecordSet\": {
            \"Name\": \"${VALIDATION_NAME}\",
            \"Type\": \"CNAME\",
            \"TTL\": 60,
            \"ResourceRecords\": [{\"Value\": \"${VALIDATION_VALUE}\"}]
          }
        }]
      }" >/dev/null

    log "Waiting for ACM to validate and issue (typically 2-5 min)..."
    sleep 300
    aws acm wait certificate-validated --region "${AWS_REGION}" --certificate-arn "${ACM_CERT_ARN}" \
      || error "certificate ${ACM_CERT_ARN} was not issued - check DNS propagation and ACM console"
    success "Certificate issued: ${ACM_CERT_ARN}"
  else
    success "Found issued certificate: ${ACM_CERT_ARN}"
  fi
fi

# --- Install ingress-nginx ---
# Idempotent: `helm upgrade --install` converges on re-run.
#
# Ports. NLB 443 (TLS, ACM) -> nginx container port 80 (plain HTTP).
# NLB 80 -> container port 2443 ("tohttps"), a tiny server that only redirects
# to https. That server is declared in the http-snippet below.
#
# Headers. The NLB TLS listener adds no X-Forwarded-* headers, so nginx would
# tell Jenkins the request was plain http. proxySetHeaders forces https/443.
# UNVERIFIED: whether this overrides nginx's own X-Forwarded-Proto. Check
# with the reverse-proxy monitor in Manage Jenkins (see the runbook).
#
# Deliberately not set: use-forwarded-headers / proxy-real-ip-cidr. The NLB
# strips nothing, so trusting X-Forwarded-For would let any client spoof its IP.
log "Installing ingress-nginx ${INGRESS_NGINX_CHART_VERSION} via Helm..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update ingress-nginx

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace "${INGRESS_NGINX_NAMESPACE}" \
  --create-namespace \
  --version "${INGRESS_NGINX_CHART_VERSION}" \
  -f - <<EOF
controller:
  ingressClassResource:
    name: ${INGRESS_CLASS_NAME}
  nodeSelector:
    workload: system
  containerPort:
    http: 80
    https: 443
    tohttps: 2443
  config:
    http-snippet: |
      server {
        listen 2443;
        return 308 https://\$host\$request_uri;
      }
    proxy-read-timeout: "3600"
    proxy-send-timeout: "3600"
  proxySetHeaders:
    X-Forwarded-Proto: https
    X-Forwarded-Port: "443"
  service:
    type: LoadBalancer
    targetPorts:
      http: tohttps
      https: http
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-type: external
      service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
      service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
      service.beta.kubernetes.io/aws-load-balancer-ssl-cert: "${ACM_CERT_ARN}"
      service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "443"
      service.beta.kubernetes.io/aws-load-balancer-ssl-negotiation-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
      service.beta.kubernetes.io/aws-load-balancer-backend-protocol: tcp
      service.beta.kubernetes.io/aws-load-balancer-additional-resource-tags: "cb-user=${TAG_CB_USER:-acaternberg},cb-owner=${TAG_CB_OWNER:-professional-services},cb-environment=${TAG_CB_ENVIRONMENT:-demo}"
EOF

log "Waiting for the ingress-nginx controller to be ready..."
kubectl rollout status deployment/ingress-nginx-controller -n "${INGRESS_NGINX_NAMESPACE}" --timeout=180s

log "Waiting for the NLB to be provisioned (a few minutes)..."
NLB_DNS=""
for _ in $(seq 1 30); do
  NLB_DNS=$(kubectl get svc ingress-nginx-controller -n "${INGRESS_NGINX_NAMESPACE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [[ -n "${NLB_DNS}" ]] && break
  echo 'wait for LB creation'
  sleep 10
done
echo

[[ -n "${NLB_DNS}" ]] \
  || error "NLB was not provisioned. Check: kubectl describe svc ingress-nginx-controller -n ${INGRESS_NGINX_NAMESPACE}"

success "NLB provisioned: ${NLB_DNS}"
log "Next: ./05-installCloudBeesNginx.sh, then ./06-installExternalDNS.sh (points ${CJOC_HOST_NAME} at the NLB)."
success "Installation completed successfully."
