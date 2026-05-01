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

# VPN-related outputs consumed by vpn/terraform/.
output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr" {
  value = var.vpc_cidr
}

output "private_route_table_ids" {
  value = module.vpc.private_route_table_ids
}

output "public_route_table_ids" {
  value = module.vpc.public_route_table_ids
}

output "vpn_gateway_id" {
  value = aws_vpn_gateway.this.id
}

output "vpn_aws_asn" {
  value = var.vpn_aws_asn
}
