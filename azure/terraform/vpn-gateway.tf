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
  # AZ SKUs require zone-redundant Public IPs. Specify all 3 zones.
  zones = ["1", "2", "3"]
}

resource "azurerm_virtual_network_gateway" "this" {
  name                = "${var.cluster_name}-vpn-gw"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  type     = "Vpn"
  vpn_type = "RouteBased"

  active_active = false
  enable_bgp    = true
  # Azure deprecated non-AZ VPN SKUs (VpnGw1, etc.) — only the *AZ
  # variants are creatable now. The azurerm provider's enum validation
  # currently only accepts VpnGw2AZ and up (VpnGw1AZ doesn't pass validation
  # despite being a real Azure SKU), so we use VpnGw2AZ — ~$0.49/hr.
  sku        = "VpnGw2AZ"
  generation = "Generation2"

  ip_configuration {
    name                          = "default"
    public_ip_address_id          = azurerm_public_ip.vpn.id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.gateway.id
  }

  bgp_settings {
    asn = var.vpn_azure_asn
  }

  # Cap the azurerm provider's poll loops on this resource. Without these
  # explicit timeouts, the default is 90m for create / 90m for delete —
  # but on real Azure the provider can sit polling for HOURS even after
  # the gateway is fully provisioned / deleted server-side, because the
  # `provisioningState` field doesn't always transition to a terminal
  # state in the response. Caught during 2026-05-04 e2e v3 — bring-up
  # spent 7+ hours in `Still creating...` after the GW was actually
  # `Succeeded` on Azure's side; the workaround was kill TF + import +
  # re-apply. Capping at 60m / 30m makes failures fast enough to
  # recover from interactively.
  #
  # If create hits the 60m cap: kill TF, then
  #   `terraform import azurerm_virtual_network_gateway.this <full-resource-id>`
  # to bring the existing GW into state, then `terraform apply` to
  # reconcile any remaining resources.
  #
  # If delete hits the 30m cap: scripts/teardown.sh's azure_sweep falls
  # back to `az group delete --name <RG> --yes --no-wait` which cascades
  # to all RG children including this gateway.
  timeouts {
    create = "60m"
    delete = "30m"
  }
}
