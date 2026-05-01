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
  # See aws_vpn_connection.to_gcp for the rationale: BGP convergence
  # was unreliable, switched to static routes.
  static_routes_only = true

  tunnel1_inside_cidr   = local.aws_to_azure_tunnel_inside_cidr
  tunnel1_preshared_key = random_password.psk_aws_azure.result

  tags = {
    Name = "to-rp-azure"
  }
}

resource "aws_vpn_connection_route" "to_azure" {
  destination_cidr_block = var.azure_vnet_cidr
  vpn_connection_id      = aws_vpn_connection.to_azure.id
}

resource "aws_route" "public_to_azure" {
  for_each               = toset(var.aws_route_table_ids)
  route_table_id         = each.value
  destination_cidr_block = var.azure_vnet_cidr
  gateway_id             = var.aws_vpn_gateway_id
}

# Azure side
resource "azurerm_local_network_gateway" "aws" {
  name                = "rp-aws-lng"
  resource_group_name = var.azure_resource_group_name
  location            = var.azure_location
  gateway_address     = aws_vpn_connection.to_azure.tunnel1_address
  # Static routing — advertise AWS VPC CIDR via this LNG.
  address_space = [var.aws_vpc_cidr]
}

resource "azurerm_virtual_network_gateway_connection" "to_aws" {
  name                = "to-rp-aws"
  resource_group_name = var.azure_resource_group_name
  location            = var.azure_location

  type                       = "IPsec"
  virtual_network_gateway_id = var.azure_vpn_gateway_id
  local_network_gateway_id   = azurerm_local_network_gateway.aws.id

  shared_key = random_password.psk_aws_azure.result
  # See aws_vpn_connection.to_azure for the rationale: switched away
  # from BGP because convergence was unreliable.
  enable_bgp = false
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
