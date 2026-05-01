#!/usr/bin/env bash
# scripts/apply-vpn.sh — collect each cloud's terraform outputs and
# `terraform apply` the cross-cloud VPN connections module.
#
# Run AFTER `terraform apply` has succeeded in each of:
#   aws/terraform/   (creates VPC + EKS + aws_vpn_gateway)
#   gcp/terraform/   (creates VPC + GKE + ha_vpn_gateway + cloud router)
#   azure/terraform/ (creates VNet + AKS + virtual_network_gateway)
#
# Usage:
#   ./apply-vpn.sh
#
# Set AWS_PROFILE / AZURE-creds / gcloud-creds in your shell first.

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$SCRIPT_DIR/.." && pwd)
AWS_TF=$REPO/aws/terraform
GCP_TF=$REPO/gcp/terraform
AZURE_TF=$REPO/azure/terraform
VPN_TF=$REPO/vpn/terraform

log() { echo "[apply-vpn] $*" >&2; }

require_tf_state() {
  local dir=$1
  if ! (cd "$dir" && terraform output -json >/dev/null 2>&1); then
    echo "error: no terraform state in $dir — apply that cloud first" >&2
    exit 1
  fi
}

require_tf_state "$AWS_TF"
require_tf_state "$GCP_TF"
require_tf_state "$AZURE_TF"

log "collecting AWS outputs"
AWS_VPC_ID=$(cd "$AWS_TF" && terraform output -raw vpc_id)
AWS_VPC_CIDR=$(cd "$AWS_TF" && terraform output -raw vpc_cidr)
AWS_VGW_ID=$(cd "$AWS_TF" && terraform output -raw vpn_gateway_id)
AWS_REGION=$(cd "$AWS_TF" && terraform output -raw region)
AWS_ASN=$(cd "$AWS_TF" && terraform output -raw vpn_aws_asn)
AWS_RT_IDS_JSON=$(cd "$AWS_TF" && terraform output -json public_route_table_ids)

log "collecting GCP outputs"
GCP_PROJECT=$(cd "$GCP_TF" && terraform output -raw project_id)
GCP_REGION=$(cd "$GCP_TF" && terraform output -raw region)
GCP_NETWORK=$(cd "$GCP_TF" && terraform output -raw network_name)
GCP_SUBNET_CIDR=$(cd "$GCP_TF" && terraform output -raw subnet_cidr)
GCP_ROUTER=$(cd "$GCP_TF" && terraform output -raw router_name)
GCP_HA_VPN_GW=$(cd "$GCP_TF" && terraform output -raw ha_vpn_gateway_self_link)
GCP_HA_IP_A=$(cd "$GCP_TF" && terraform output -raw ha_vpn_gateway_ip_a)
GCP_HA_IP_B=$(cd "$GCP_TF" && terraform output -raw ha_vpn_gateway_ip_b)
GCP_ASN=$(cd "$GCP_TF" && terraform output -raw vpn_gcp_asn)

log "collecting Azure outputs"
AZ_RG=$(cd "$AZURE_TF" && terraform output -raw resource_group)
AZ_LOCATION=$(cd "$AZURE_TF" && terraform output -raw region)
AZ_VNET_CIDR=$(cd "$AZURE_TF" && terraform output -raw vnet_cidr)
AZ_VPN_GW_ID=$(cd "$AZURE_TF" && terraform output -raw vpn_gateway_id)
AZ_VPN_PIP=$(cd "$AZURE_TF" && terraform output -raw vpn_gateway_public_ip)
AZ_VPN_BGP_IP=$(cd "$AZURE_TF" && terraform output -raw vpn_gateway_bgp_peering_address)
AZ_ASN=$(cd "$AZURE_TF" && terraform output -raw vpn_azure_asn)

log "applying vpn/terraform"
cd "$VPN_TF"
terraform init -upgrade >/dev/null
terraform apply -auto-approve \
  -var "aws_region=$AWS_REGION" \
  -var "aws_vpc_id=$AWS_VPC_ID" \
  -var "aws_vpc_cidr=$AWS_VPC_CIDR" \
  -var "aws_route_table_ids=$AWS_RT_IDS_JSON" \
  -var "aws_vpn_gateway_id=$AWS_VGW_ID" \
  -var "aws_asn=$AWS_ASN" \
  -var "gcp_project_id=$GCP_PROJECT" \
  -var "gcp_region=$GCP_REGION" \
  -var "gcp_network_name=$GCP_NETWORK" \
  -var "gcp_subnet_cidr=$GCP_SUBNET_CIDR" \
  -var "gcp_router_name=$GCP_ROUTER" \
  -var "gcp_ha_vpn_gateway_self_link=$GCP_HA_VPN_GW" \
  -var "gcp_ha_vpn_gateway_ip_a=$GCP_HA_IP_A" \
  -var "gcp_ha_vpn_gateway_ip_b=$GCP_HA_IP_B" \
  -var "gcp_asn=$GCP_ASN" \
  -var "azure_resource_group_name=$AZ_RG" \
  -var "azure_location=$AZ_LOCATION" \
  -var "azure_vnet_cidr=$AZ_VNET_CIDR" \
  -var "azure_vpn_gateway_id=$AZ_VPN_GW_ID" \
  -var "azure_vpn_gateway_public_ip=$AZ_VPN_PIP" \
  -var "azure_vpn_gateway_bgp_peering_address=$AZ_VPN_BGP_IP" \
  -var "azure_asn=$AZ_ASN"

log "done"
