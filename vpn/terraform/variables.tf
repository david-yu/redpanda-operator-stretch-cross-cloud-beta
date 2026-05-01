# All inputs come from the per-cloud terraform outputs. Wrap the
# `terraform apply` invocation in scripts/apply-vpn.sh to pull them
# automatically; or pass them manually via -var.

# AWS
variable "aws_region" {
  type    = string
  default = "us-east-1"
}
variable "aws_vpc_id" { type = string }
variable "aws_vpc_cidr" { type = string }
variable "aws_route_table_ids" { type = list(string) }
variable "aws_vpn_gateway_id" { type = string }
variable "aws_asn" {
  type    = number
  default = 64512
}

# GCP
variable "gcp_project_id" { type = string }
variable "gcp_region" {
  type    = string
  default = "us-east1"
}
variable "gcp_network_name" { type = string }
variable "gcp_subnet_cidr" { type = string }
variable "gcp_router_name" { type = string }
variable "gcp_ha_vpn_gateway_self_link" { type = string }
variable "gcp_ha_vpn_gateway_ip_a" { type = string }
variable "gcp_ha_vpn_gateway_ip_b" { type = string }
variable "gcp_asn" {
  type    = number
  default = 64513
}

# Azure
variable "azure_resource_group_name" { type = string }
variable "azure_location" {
  type    = string
  default = "eastus"
}
variable "azure_vnet_cidr" { type = string }
variable "azure_vpn_gateway_id" { type = string }
variable "azure_vpn_gateway_public_ip" { type = string }
variable "azure_vpn_gateway_bgp_peering_address" { type = string }
variable "azure_asn" {
  type    = number
  default = 64514
}
