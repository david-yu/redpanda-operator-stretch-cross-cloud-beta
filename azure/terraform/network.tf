resource "azurerm_virtual_network" "this" {
  name                = "${var.cluster_name}-vnet"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.vnet_cidr]
}

resource "azurerm_subnet" "nodes" {
  name                 = "${var.cluster_name}-nodes"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.subnet_cidr]
}

# NSG on the node subnet allows the cross-cloud Cilium / Redpanda ports
# from anywhere — the other clouds' egress IPs aren't predictable. Tighten
# in production by restricting source_address_prefixes to known ranges.
resource "azurerm_network_security_group" "nodes" {
  name                = "${var.cluster_name}-nodes-nsg"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_network_security_rule" "cross_cloud_tcp" {
  for_each = { for p in var.cross_cloud_tcp_ports : tostring(p) => p }

  name                        = "cross-cloud-tcp-${each.key}"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.nodes.name

  priority                   = 100 + tonumber(each.key) % 1000
  direction                  = "Inbound"
  access                     = "Allow"
  protocol                   = "Tcp"
  source_port_range          = "*"
  destination_port_range     = each.key
  source_address_prefix      = "Internet"
  destination_address_prefix = "*"
}

resource "azurerm_network_security_rule" "cross_cloud_udp" {
  for_each = { for p in var.cross_cloud_udp_ports : tostring(p) => p }

  name                        = "cross-cloud-udp-${each.key}"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.nodes.name

  priority                   = 200 + tonumber(each.key) % 1000
  direction                  = "Inbound"
  access                     = "Allow"
  protocol                   = "Udp"
  source_port_range          = "*"
  destination_port_range     = each.key
  source_address_prefix      = "Internet"
  destination_address_prefix = "*"
}

resource "azurerm_subnet_network_security_group_association" "nodes" {
  subnet_id                 = azurerm_subnet.nodes.id
  network_security_group_id = azurerm_network_security_group.nodes.id
}
