# Pre-shared keys for the IPsec tunnels — one per pair. Generated once
# per `terraform apply`, persisted in state so the same key is used on
# both sides of each tunnel.
resource "random_password" "psk_aws_gcp" {
  length  = 32
  special = false
}
resource "random_password" "psk_aws_azure" {
  length  = 32
  special = false
}
resource "random_password" "psk_gcp_azure" {
  length  = 32
  special = false
}

# Link-local /30s for BGP transit on each tunnel. Each tunnel gets a
# /30: AWS tunnels get inside_cidr_a / b; we hand-allocate matching
# /30s for the GCP <-> Azure tunnels.
locals {
  # AWS auto-allocates tunnel inside CIDRs from 169.254.x.0/30 unless we
  # set them explicitly. Below we set them explicitly so BGP peer IPs
  # are predictable on the GCP / Azure side.
  aws_to_gcp_tunnel_inside_cidr = "169.254.10.0/30"
  aws_to_azure_tunnel_inside_cidr = "169.254.20.0/30"

  # GCP <-> Azure has no AWS in the loop, so we pick the BGP transit
  # /30 ourselves.
  gcp_to_azure_tunnel_a_cidr = "169.254.30.0/30"
  gcp_to_azure_tunnel_b_cidr = "169.254.30.4/30"

  # AWS BGP peer addresses derived from the tunnel inside CIDR.
  # AWS uses the .2 of the /30 for the AWS side, .1 for the customer.
  aws_to_gcp_aws_bgp_ip      = "169.254.10.2"
  aws_to_gcp_customer_bgp_ip = "169.254.10.1"

  aws_to_azure_aws_bgp_ip      = "169.254.20.2"
  aws_to_azure_customer_bgp_ip = "169.254.20.1"

  # GCP <-> Azure BGP IPs.
  gcp_to_azure_a_gcp_bgp_ip   = "169.254.30.1"
  gcp_to_azure_a_azure_bgp_ip = "169.254.30.2"
  gcp_to_azure_b_gcp_bgp_ip   = "169.254.30.5"
  gcp_to_azure_b_azure_bgp_ip = "169.254.30.6"
}
