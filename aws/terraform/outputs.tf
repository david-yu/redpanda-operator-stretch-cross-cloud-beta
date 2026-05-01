output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "region" {
  value = var.region
}

output "kubectl_setup_command" {
  description = "Run this to load the EKS context into your local kubeconfig under the alias `rp-aws`."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name} --alias rp-aws"
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "pod_cidr" {
  description = "Pod CIDR Cilium will hand out from. Pass to `cilium install --set ipam.operator.clusterPoolIPv4PodCIDRList=...`."
  value       = var.pod_cidr
}

output "service_cidr" {
  value = var.service_cidr
}
