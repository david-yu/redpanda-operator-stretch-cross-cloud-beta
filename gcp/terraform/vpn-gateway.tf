# GCP HA VPN gateway + Cloud Router. The cross-cloud tunnels and BGP peers
# are created in vpn/terraform/ — the gateway here just exposes the two
# public IPs that AWS / Azure point their customer_gateways at.

resource "google_compute_ha_vpn_gateway" "this" {
  name    = "${var.cluster_name}-ha-vpn"
  network = google_compute_network.this.self_link
  region  = var.region
}

resource "google_compute_router" "this" {
  name    = "${var.cluster_name}-router"
  region  = var.region
  network = google_compute_network.this.name

  bgp {
    asn = var.vpn_gcp_asn
  }
}
