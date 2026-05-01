# AWS ↔ Azure IPsec tunnel with BGP.
#
# AWS side: 1 customer_gateway pointing at Azure VPN GW public IP,
# 1 vpn_connection (we wire tunnel1; tunnel2 stays DOWN — same pattern
# as AWS↔GCP).
#
# Azure side: 1 local_network_gateway pointing at AWS tunnel1 outside
# IP, 1 vpn_gateway_connection with BGP.

resource "aws_customer_gateway" "azure" {
  device_name = "rp-azure"
  bgp_asn     = var.azure_asn
  ip_address  = var.azure_vpn_gateway_public_ip
  type        = "ipsec.1"
  tags = {
    Name = "rp-azure-cgw"
  }
}

resource "aws_vpn_connection" "to_azure" {
  vpn_gateway_id      = var.aws_vpn_gateway_id
  customer_gateway_id = aws_customer_gateway.azure.id
  type                = "ipsec.1"
  static_routes_only  = false

  tunnel1_inside_cidr   = local.aws_to_azure_tunnel_inside_cidr
  tunnel1_preshared_key = random_password.psk_aws_azure.result

  tags = {
    Name = "to-rp-azure"
  }
}

# Azure side
resource "azurerm_local_network_gateway" "aws" {
  name                = "rp-aws-lng"
  resource_group_name = var.azure_resource_group_name
  location            = var.azure_location
  gateway_address     = aws_vpn_connection.to_azure.tunnel1_address

  bgp_settings {
    asn                 = var.aws_asn
    bgp_peering_address = local.aws_to_azure_aws_bgp_ip
  }
}

resource "azurerm_virtual_network_gateway_connection" "to_aws" {
  name                = "to-rp-aws"
  resource_group_name = var.azure_resource_group_name
  location            = var.azure_location

  type                       = "IPsec"
  virtual_network_gateway_id = var.azure_vpn_gateway_id
  local_network_gateway_id   = azurerm_local_network_gateway.aws.id

  shared_key  = random_password.psk_aws_azure.result
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
