resource "google_compute_network" "this" {
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "this" {
  name          = "${var.cluster_name}-subnet"
  region        = var.region
  network       = google_compute_network.this.id
  ip_cidr_range = var.subnet_cidr

  # Secondary ranges for VPC-native GKE (pod IPs come from `pods`, service
  # IPs come from `services`). These names are referenced from gke.tf.
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pod_cidr
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.service_cidr
  }
}

# Inbound firewall rules from other clouds. Open to 0.0.0.0/0 because
# the other clouds' node IPs aren't predictable; tighten to known CIDR
# blocks in production.
resource "google_compute_firewall" "cross_cloud_tcp" {
  name        = "${var.cluster_name}-cross-cloud-tcp"
  network     = google_compute_network.this.name
  description = "cross-cloud cilium clustermesh + redpanda tcp"

  allow {
    protocol = "tcp"
    ports    = [for p in var.cross_cloud_tcp_ports : tostring(p)]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["${var.cluster_name}-node"]
}

resource "google_compute_firewall" "cross_cloud_udp" {
  name        = "${var.cluster_name}-cross-cloud-udp"
  network     = google_compute_network.this.name
  description = "cross-cloud cilium wireguard/vxlan udp"

  allow {
    protocol = "udp"
    ports    = [for p in var.cross_cloud_udp_ports : tostring(p)]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["${var.cluster_name}-node"]
}

# GKE master ↔ node ↔ pod intra-VPC traffic. GKE creates its own rules but
# we also need pod-CIDR ↔ pod-CIDR within the VPC for Cilium tunnels.
resource "google_compute_firewall" "intra_vpc" {
  name        = "${var.cluster_name}-intra-vpc"
  network     = google_compute_network.this.name
  description = "intra-VPC traffic for cilium tunnels"

  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }
  source_ranges = [var.subnet_cidr, var.pod_cidr, var.service_cidr]
}
