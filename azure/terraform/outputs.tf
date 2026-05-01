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
