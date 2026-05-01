# AWS ↔ GCP IPsec tunnel with BGP.
#
# AWS side (1 customer_gateway + 1 vpn_connection — AWS always creates
# 2 tunnels per connection but we only wire tunnel1 to GCP for demo
# simplicity; tunnel2 stays DOWN, AWS uses tunnel1 for active traffic):
#   - aws_customer_gateway.gcp_a → GCP HA VPN ip_a
#   - aws_vpn_connection.to_gcp  → vgw + customer_gateway, BGP enabled
#   - aws_vpn_connection_route.* → static routes to GCP CIDR (belt & braces; BGP also propagates)
#   - aws_vpn_gateway_route_propagation.* → enables BGP-learned routes on private/public RTs
#
# GCP side:
#   - google_compute_external_vpn_gateway → AWS tunnel1 outside IP
#   - google_compute_vpn_tunnel  → encrypted with PSK, peers via BGP
#   - google_compute_router_interface → Cloud Router transit interface
#   - google_compute_router_peer       → BGP peer on the AWS side

resource "aws_customer_gateway" "gcp" {
  device_name = "rp-gcp"
  bgp_asn     = var.gcp_asn
  ip_address  = var.gcp_ha_vpn_gateway_ip_a
  type        = "ipsec.1"
  tags = {
    Name = "rp-gcp-cgw"
  }
}

resource "aws_vpn_connection" "to_gcp" {
  vpn_gateway_id      = var.aws_vpn_gateway_id
  customer_gateway_id = aws_customer_gateway.gcp.id
  type                = "ipsec.1"

  # NOTE: AWS↔GCP HA-VPN BGP convergence is fragile in practice — IPsec
  # establishes cleanly but the BGP session sticks in Connect/Connecting
  # for hours despite matching ASNs/PSKs/inside-CIDRs. The
  # devgenius.io article on this exact pairing recommends using static
  # routes on both sides instead of BGP, so we follow that here:
  # static_routes_only=true on AWS, manual aws_vpn_connection_route +
  # google_compute_route on the peer side.
  static_routes_only = true

  tunnel1_inside_cidr   = local.aws_to_gcp_tunnel_inside_cidr
  tunnel1_preshared_key = random_password.psk_aws_gcp.result

  tags = {
    Name = "to-rp-gcp"
  }
}

# Static route on the AWS side: traffic to GCP subnet CIDR exits via
# this VPN connection.
resource "aws_vpn_connection_route" "to_gcp" {
  destination_cidr_block = var.gcp_subnet_cidr
  vpn_connection_id      = aws_vpn_connection.to_gcp.id
}

# Static route on every public route table so traffic destined to the
# GCP subnet CIDR is forwarded to the VGW (which then routes it through
# the VPN connection above).
resource "aws_route" "public_to_gcp" {
  for_each               = toset(var.aws_route_table_ids)
  route_table_id         = each.value
  destination_cidr_block = var.gcp_subnet_cidr
  gateway_id             = var.aws_vpn_gateway_id
}

resource "aws_vpn_gateway_route_propagation" "to_gcp_private" {
  count          = length(var.aws_route_table_ids)
  vpn_gateway_id = var.aws_vpn_gateway_id
  route_table_id = var.aws_route_table_ids[count.index]
}

# GCP side
resource "google_compute_external_vpn_gateway" "aws" {
  name            = "rp-aws-ext-gw"
  redundancy_type = "SINGLE_IP_INTERNALLY_REDUNDANT"
  description     = "AWS site-to-site VPN endpoint"
  interface {
    id         = 0
    ip_address = aws_vpn_connection.to_gcp.tunnel1_address
  }
}

resource "google_compute_vpn_tunnel" "to_aws" {
  name                            = "to-rp-aws"
  region                          = var.gcp_region
  vpn_gateway                     = var.gcp_ha_vpn_gateway_self_link
  vpn_gateway_interface           = 0
  peer_external_gateway           = google_compute_external_vpn_gateway.aws.self_link
  peer_external_gateway_interface = 0
  shared_secret                   = random_password.psk_aws_gcp.result
  router                          = var.gcp_router_name
  ike_version                     = 2
}

# GCP HA VPN strictly requires BGP — without router_interface +
# router_peer GCP refuses to make the tunnel operational. We keep the
# BGP wiring but expect the peer to stay DOWN (AWS now uses
# static_routes_only=true and won't BGP-advertise back). The actual
# routing is via the explicit google_compute_route below; the BGP
# session existing in DOWN state is harmless overhead.
resource "google_compute_router_interface" "to_aws" {
  name       = "to-rp-aws-iface"
  region     = var.gcp_region
  router     = var.gcp_router_name
  ip_range   = "${local.aws_to_gcp_customer_bgp_ip}/30"
  vpn_tunnel = google_compute_vpn_tunnel.to_aws.name
}

resource "google_compute_router_peer" "to_aws" {
  name                      = "to-rp-aws-bgp"
  region                    = var.gcp_region
  router                    = var.gcp_router_name
  peer_ip_address           = local.aws_to_gcp_aws_bgp_ip
  peer_asn                  = var.aws_asn
  interface                 = google_compute_router_interface.to_aws.name
  advertised_route_priority = 100
}

# Manual route for the actual AWS-bound traffic — bypasses the (DOWN)
# BGP session.
resource "google_compute_route" "to_aws" {
  name                = "to-rp-aws-via-vpn"
  network             = var.gcp_network_name
  dest_range          = var.aws_vpc_cidr
  next_hop_vpn_tunnel = google_compute_vpn_tunnel.to_aws.id
  priority            = 1000
}
