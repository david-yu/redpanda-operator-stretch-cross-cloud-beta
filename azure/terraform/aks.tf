# AKS in BYOCNI mode (network_plugin = "none"). The cluster comes up with
# NO CNI installed; pods on every node sit NotReady until you `cilium
# install`. This is the cleanest way to run Cilium on AKS — neither
# `kubenet` nor `azure` (Azure CNI) is touching the node when Cilium
# arrives.
resource "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version

  network_profile {
    network_plugin = "none"
    service_cidr   = var.service_cidr
    dns_service_ip = var.dns_service_ip
  }

  default_node_pool {
    name           = "default"
    node_count     = var.node_count
    vm_size        = var.vm_size
    os_disk_size_gb = var.node_disk_size_gb
    vnet_subnet_id = azurerm_subnet.nodes.id

    # Public IP per node so other clouds can reach it directly for
    # Cilium WireGuard / VXLAN tunnels.
    node_public_ip_enabled = true

    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  # AKS managed identity needs Network Contributor on the BYO subnet so
  # AKS can attach NICs to it.
  depends_on = [azurerm_subnet_network_security_group_association.nodes]
}

resource "azurerm_role_assignment" "aks_subnet" {
  scope                = azurerm_subnet.nodes.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.this.identity[0].principal_id
}
