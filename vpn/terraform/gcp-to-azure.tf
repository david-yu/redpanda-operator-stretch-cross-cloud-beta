# GCP ↔ Azure IPsec tunnel with BGP.
#
# GCP HA VPN has 2 interfaces; we create 2 tunnels (one per HA VPN
# interface) to the same Azure VPN GW public IP, both BGP-paired with
# the Azure side. Azure side has 1 local_network_gateway (Azure can
# point at multiple IPs only with multiple LNGs; for HA we'd add a
# second LNG. Single LNG keeps the demo wiring tight).

resource "google_compute_external_vpn_gateway" "azure" {
  name            = "rp-azure-ext-gw"
  redundancy_type = "SINGLE_IP_INTERNALLY_REDUNDANT"
  description     = "Azure VPN Gateway endpoint"
  interface {
    id         = 0
    ip_address = var.azure_vpn_gateway_public_ip
  }
}

resource "google_compute_vpn_tunnel" "to_azure_a" {
  name                            = "to-rp-azure-a"
  region                          = var.gcp_region
  vpn_gateway                     = var.gcp_ha_vpn_gateway_self_link
  vpn_gateway_interface           = 0
  peer_external_gateway           = google_compute_external_vpn_gateway.azure.self_link
  peer_external_gateway_interface = 0
  shared_secret                   = random_password.psk_gcp_azure.result
  router                          = var.gcp_router_name
  ike_version                     = 2
}

resource "google_compute_router_interface" "to_azure_a" {
  name       = "to-rp-azure-a-iface"
  region     = var.gcp_region
  router     = var.gcp_router_name
  ip_range   = "${local.gcp_to_azure_a_gcp_bgp_ip}/30"
  vpn_tunnel = google_compute_vpn_tunnel.to_azure_a.name
}

resource "google_compute_router_peer" "to_azure_a" {
  name                      = "to-rp-azure-a-bgp"
  region                    = var.gcp_region
  router                    = var.gcp_router_name
  peer_ip_address           = local.gcp_to_azure_a_azure_bgp_ip
  peer_asn                  = var.azure_asn
  interface                 = google_compute_router_interface.to_azure_a.name
  advertised_route_priority = 100
}

# Azure side
resource "azurerm_local_network_gateway" "gcp" {
  name                = "rp-gcp-lng"
  resource_group_name = var.azure_resource_group_name
  location            = var.azure_location
  gateway_address     = var.gcp_ha_vpn_gateway_ip_a

  bgp_settings {
    asn                 = var.gcp_asn
    bgp_peering_address = local.gcp_to_azure_a_gcp_bgp_ip
  }
}

resource "azurerm_virtual_network_gateway_connection" "to_gcp" {
  name                = "to-rp-gcp"
  resource_group_name = var.azure_resource_group_name
  location            = var.azure_location

  type                       = "IPsec"
  virtual_network_gateway_id = var.azure_vpn_gateway_id
  local_network_gateway_id   = azurerm_local_network_gateway.gcp.id

  shared_key  = random_password.psk_gcp_azure.result
  enable_bgp  = true
  ipsec_policy {
    dh_group         = "DHGroup14"
    ike_encryption   = "AES256"
    ike_integrity    = "SHA256"
    ipsec_encryption = "AES256"
    ipsec_integrity  = "SHA256"
    pfs_group        = "PFS14"
    sa_lifetime      = 3600
  }
}
