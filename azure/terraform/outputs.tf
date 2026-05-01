output "cluster_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "resource_group" {
  value = azurerm_resource_group.this.name
}

output "region" {
  value = azurerm_resource_group.this.location
}

output "kubectl_setup_command" {
  description = "Run this to fetch AKS credentials and rename the context to `rp-azure`."
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.this.name} --name ${azurerm_kubernetes_cluster.this.name} --overwrite-existing && kubectl config rename-context ${azurerm_kubernetes_cluster.this.name} rp-azure"
}

output "pod_cidr" {
  value = var.pod_cidr
}

output "service_cidr" {
  value = var.service_cidr
}

# VPN-related outputs consumed by vpn/terraform/.
output "vnet_name" {
  value = azurerm_virtual_network.this.name
}

output "vnet_cidr" {
  value = var.vnet_cidr
}

output "vpn_gateway_id" {
  value = azurerm_virtual_network_gateway.this.id
}

output "vpn_gateway_public_ip" {
  description = "Public IP of the Azure VPN Gateway. AWS customer_gateway and GCP external_vpn_gateway point at this."
  value       = azurerm_public_ip.vpn.ip_address
}

output "vpn_gateway_bgp_peering_address" {
  description = "BGP peering IP inside the Azure VPN Gateway. Used by AWS / GCP BGP peer config."
  value       = azurerm_virtual_network_gateway.this.bgp_settings[0].peering_addresses[0].default_addresses[0]
}

output "vpn_azure_asn" {
  value = var.vpn_azure_asn
}
