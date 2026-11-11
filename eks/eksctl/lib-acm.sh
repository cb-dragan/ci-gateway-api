#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# lib-acm.sh — Sourced by 04-deleteEnvoy.sh, 04-deleteNginx.sh and
# 07-deleteEC2WithController.sh. Not run on its own.
#
# delete_acm_certificate <cert-arn> <route53-zone-domain>
#   Deletes the ACM certificate, then the DNS-validation CNAME that the install
#   scripts upserted into Route53 for it (ACM never removes that record).
#   Warns instead of failing, so a teardown goes on.
#
# The caller provides AWS_REGION and the log/success/warn helpers.
# -----------------------------------------------------------------------------
delete_acm_certificate() {
  local arn="$1" zone_domain="$2" rec_name rec_value zone_id ttl current

  # Read the validation record first: it cannot be described after the delete.
  read -r rec_name rec_value < <(aws acm describe-certificate --region "${AWS_REGION}" \
    --certificate-arn "${arn}" \
    --query "Certificate.DomainValidationOptions[0].ResourceRecord.[Name,Value]" \
    --output text 2>/dev/null || echo "")

  if ! aws acm delete-certificate --region "${AWS_REGION}" --certificate-arn "${arn}" 2>/dev/null; then
    warn "Could not delete ${arn} - it is probably still in use by a load balancer."
    return 0
  fi
  success "Certificate deleted."
  [[ -n "${rec_name:-}" && "${rec_name}" != "None" ]] || return 0

  zone_id=$(aws route53 list-hosted-zones-by-name --dns-name "${zone_domain}." \
    --query "HostedZones[?Name=='${zone_domain}.' && Config.PrivateZone==\`false\`].Id | [0]" \
    --output text 2>/dev/null | sed 's#/hostedzone/##' || true)
  if [[ -z "${zone_id}" || "${zone_id}" == "None" ]]; then
    warn "No public zone for ${zone_domain}: remove the validation CNAME ${rec_name} by hand."
    return 0
  fi

  # Delete only the exact record the install script created (Route53 needs matching values).
  read -r ttl current < <(aws route53 list-resource-record-sets --hosted-zone-id "${zone_id}" \
    --query "ResourceRecordSets[?Name=='${rec_name}' && Type=='CNAME'] | [0].[TTL, ResourceRecords[0].Value]" \
    --output text 2>/dev/null || echo "")
  if [[ "${current:-}" != "${rec_value}" ]]; then
    log "No matching validation record ${rec_name}; nothing to remove."
    return 0
  fi
  aws route53 change-resource-record-sets --hosted-zone-id "${zone_id}" --change-batch \
    "{\"Changes\":[{\"Action\":\"DELETE\",\"ResourceRecordSet\":{\"Name\":\"${rec_name}\",\"Type\":\"CNAME\",\"TTL\":${ttl},\"ResourceRecords\":[{\"Value\":\"${rec_value}\"}]}}]}" \
    >/dev/null \
    && success "Validation record ${rec_name} removed." \
    || warn "Could not remove the validation record ${rec_name}."
}
