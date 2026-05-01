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
