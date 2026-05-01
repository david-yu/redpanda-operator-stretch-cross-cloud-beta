# Azure VPN Gateway. Lives in the dedicated `GatewaySubnet` (Azure reserves
# that exact name). active_active=false to keep cost down and the
# wiring in vpn/terraform/ simpler — single public IP per peer.
#
# Provisioning a VPN Gateway takes ~30-45 minutes; expect that on first
# `terraform apply`.

resource "azurerm_subnet" "gateway" {
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.gateway_subnet_cidr]
}

resource "azurerm_public_ip" "vpn" {
  name                = "${var.cluster_name}-vpn-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_virtual_network_gateway" "this" {
  name                = "${var.cluster_name}-vpn-gw"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  type     = "Vpn"
  vpn_type = "RouteBased"

  active_active = false
  enable_bgp    = true
  sku           = "VpnGw1"
  generation    = "Generation1"

  ip_configuration {
    name                          = "default"
    public_ip_address_id          = azurerm_public_ip.vpn.id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.gateway.id
  }

  bgp_settings {
    asn = var.vpn_azure_asn
  }
}
