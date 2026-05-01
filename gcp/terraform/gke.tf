# GKE cluster configured to play nicely with Cilium ClusterMesh:
#   - datapath_provider = LEGACY_DATAPATH (NOT GKE Dataplane V2 / ADVANCED).
#     DPv2 is GKE's own Cilium fork and does NOT support clustermesh; you
#     have to opt out and install standard Cilium.
#   - network_policy { enabled = false } — Calico is the default policy
#     engine on GKE, but Cilium will own policy once installed.
#   - addons_config { network_policy_config.disabled = true } — same reason.
#   - VPC-native (ip_allocation_policy with named secondary ranges) so pod
#     and service IPs come from our planned non-overlapping CIDRs.
#
# After `terraform apply`, the cluster is up but pods are NotReady because
# the kube-proxy + GKE default networking stack don't expose the API
# Cilium expects. `cilium install` (via scripts/install-cilium.sh) replaces
# the CNI and brings everything to Ready.
resource "google_container_cluster" "this" {
  name     = var.cluster_name
  location = var.region

  release_channel {
    channel = var.kubernetes_version
  }

  network    = google_compute_network.this.name
  subnetwork = google_compute_subnetwork.this.name

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  datapath_provider = "LEGACY_DATAPATH"

  network_policy {
    enabled = false
  }

  addons_config {
    network_policy_config {
      disabled = true
    }
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
  }

  # Required when you bring your own node pool.
  remove_default_node_pool = true
  initial_node_count       = 1

  deletion_protection = false
}

resource "google_container_node_pool" "default" {
  name       = "default"
  cluster    = google_container_cluster.this.name
  location   = var.region
  node_count = var.node_count

  node_config {
    machine_type = var.machine_type
    disk_size_gb = var.node_disk_size_gb
    disk_type    = "pd-balanced"
    image_type   = "COS_CONTAINERD"
    tags         = ["${var.cluster_name}-node"]

    # Public node IPs are GKE Standard's default — keep them so the other
    # clouds can reach this node directly for Cilium WireGuard tunnels.
    # (Workload Identity is unnecessary for this demo; omit the workload
    # metadata config to avoid requiring `workload_identity_config` on
    # the cluster.)

    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}
