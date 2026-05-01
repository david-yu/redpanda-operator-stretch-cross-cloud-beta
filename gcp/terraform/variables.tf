variable "project_id" {
  description = "GCP project ID where the GKE cluster will be created."
  type        = string
}

variable "project_name" {
  description = "Tag value for cost allocation / cleanup."
  type        = string
  default     = "redpanda-stretch-cross-cloud"
}

variable "region" {
  description = "GCP region. Pick one with low RTT to your AWS and Azure regions — us-east1 (South Carolina) pairs well with AWS us-east-1 and Azure eastus (~5-15ms cross-cloud)."
  type        = string
  default     = "us-east1"
}

variable "cluster_name" {
  description = "Name of the GKE cluster (also the kubectl context alias)."
  type        = string
  default     = "rp-gcp"
}

variable "kubernetes_version" {
  description = "GKE release channel. RAPID tracks the latest GA minor; pick one whose minor is supported by the Cilium version you'll install (Cilium 1.16+ supports K8s 1.27 through 1.34)."
  type        = string
  default     = "RAPID"
  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE"], var.kubernetes_version)
    error_message = "Pick one of RAPID, REGULAR, STABLE."
  }
}

variable "subnet_cidr" {
  description = "Subnet CIDR. Must NOT overlap the AWS / Azure VPC CIDRs (defaults 10.10/16, 10.20/16, 10.30/16)."
  type        = string
  default     = "10.20.0.0/16"
}

# Pod and service CIDRs are configured as secondary ranges on the subnet
# (GKE VPC-native). Cilium will be installed in `ipam.mode=kubernetes` so
# it hands out from the same pod CIDR GKE allocates per node.
variable "pod_cidr" {
  description = "Pod (secondary) CIDR. MUST NOT overlap the other clusters' pod CIDRs (defaults 10.110/16 AWS, 10.120/16 here, 10.130/16 Azure)."
  type        = string
  default     = "10.120.0.0/16"
}

variable "service_cidr" {
  description = "Service (secondary) CIDR."
  type        = string
  default     = "10.121.0.0/20"
}

variable "machine_type" {
  description = "GCE machine type for the node pool."
  type        = string
  default     = "n2-standard-4"
}

variable "node_count" {
  description = "Per-zone node count for the regional node pool. Regional clusters distribute this to each of the region's zones (typically 3), so node_count=1 → 3 nodes total — enough for the 2 broker pods + Cilium + cert-manager + operator."
  type        = number
  default     = 1
}

variable "node_disk_size_gb" {
  description = "Boot disk size for each node (GiB)."
  type        = number
  default     = 50
}

variable "cross_cloud_tcp_ports" {
  description = "TCP ports allowed inbound from other clouds (Cilium clustermesh-apiserver, Cilium health, Redpanda)."
  type        = list(number)
  default     = [2379, 4240, 9443, 33145, 9093, 8082, 9644]
}

variable "cross_cloud_udp_ports" {
  description = "UDP ports allowed inbound (Cilium WireGuard / VXLAN)."
  type        = list(number)
  default     = [51871, 8472]
}

variable "vpn_gcp_asn" {
  description = "BGP ASN for the GCP Cloud Router. Must be distinct from aws / azure ASNs."
  type        = number
  default     = 64513
}
