output "cluster_name" {
  value = google_container_cluster.this.name
}

output "region" {
  value = var.region
}

output "project_id" {
  value = var.project_id
}

output "kubectl_setup_command" {
  description = "Run this to fetch GKE credentials and rename the context to `rp-gcp`."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.this.name} --region ${var.region} --project ${var.project_id} && kubectl config rename-context gke_${var.project_id}_${var.region}_${google_container_cluster.this.name} rp-gcp"
}

output "pod_cidr" {
  description = "Pod CIDR range. Cilium uses ipam.mode=kubernetes on GKE so this comes from the GKE-allocated per-node /24s within this CIDR."
  value       = var.pod_cidr
}

output "service_cidr" {
  value = var.service_cidr
}

# VPN-related outputs consumed by vpn/terraform/.
output "network_name" {
  value = google_compute_network.this.name
}

output "subnet_cidr" {
  value = var.subnet_cidr
}

output "router_name" {
  value = google_compute_router.this.name
}

output "ha_vpn_gateway_self_link" {
  value = google_compute_ha_vpn_gateway.this.self_link
}

output "ha_vpn_gateway_ip_a" {
  description = "First of HA VPN gateway's two interface IPs (vpn_interfaces[0]). AWS / Azure customer_gateways point at this."
  value       = google_compute_ha_vpn_gateway.this.vpn_interfaces[0].ip_address
}

output "ha_vpn_gateway_ip_b" {
  description = "Second of HA VPN gateway's two interface IPs (vpn_interfaces[1])."
  value       = google_compute_ha_vpn_gateway.this.vpn_interfaces[1].ip_address
}

output "vpn_gcp_asn" {
  value = var.vpn_gcp_asn
}
