variable "project_name" {
  description = "Tag value for cost allocation / cleanup."
  type        = string
  default     = "redpanda-stretch-cross-cloud"
}

variable "owner" {
  description = "Tag value identifying the owner."
  type        = string
  default     = "redpanda-operator-stretch-cross-cloud-beta"
}

variable "region" {
  description = "AWS region for the EKS cluster. Pick one with low RTT to your GCP and Azure regions — US East Coast (us-east-1) pairs well with GCP us-east1 and Azure eastus (~5-15ms cross-cloud)."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster (also the kubectl context alias after rename)."
  type        = string
  default     = "rp-aws"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version. Cilium 1.16+ supports K8s 1.27 through 1.34."
  type        = string
  default     = "1.34"
}

variable "vpc_cidr" {
  description = "VPC CIDR. Must NOT overlap the GCP / Azure VPC CIDRs (defaults are 10.10/16, 10.20/16, 10.30/16)."
  type        = string
  default     = "10.10.0.0/16"
}

# Pod and Service CIDRs are managed by Cilium (not AWS VPC CNI), so they
# don't need to be in the VPC CIDR space — but they MUST NOT overlap with
# any other cluster's pod/service CIDRs in the mesh, or Cilium clustermesh
# routing breaks.
variable "pod_cidr" {
  description = "Pod CIDR Cilium will hand out from. Must NOT overlap the other clusters' pod CIDRs (defaults 10.110/16 here, 10.120/16 GCP, 10.130/16 Azure)."
  type        = string
  default     = "10.110.0.0/16"
}

variable "service_cidr" {
  description = "Service (cluster IP) CIDR. Configured at EKS-create time and used by kube-proxy / Cilium kubeProxyReplacement."
  type        = string
  default     = "10.111.0.0/20"
}

variable "node_instance_type" {
  description = "EC2 instance type for the node group."
  type        = string
  default     = "m5.xlarge"
}

variable "node_count" {
  description = "Desired/min/max node count. 2 nodes is enough for the 2 broker pods + Cilium agents + cert-manager + operator at the cross-cloud demo's scale."
  type        = number
  default     = 2
}

variable "node_volume_size_gb" {
  description = "Root EBS volume size for each node (GiB)."
  type        = number
  default     = 50
}

# Ports that must be reachable on this cluster's nodes from the OTHER
# clouds' node CIDRs (or 0.0.0.0/0 for the demo since cross-cloud node IPs
# aren't predictable):
#   51871/udp — Cilium WireGuard node-to-node encryption
#   8472/udp  — Cilium VXLAN (alternative to WireGuard; harmless if unused)
#   2379/tcp  — Cilium clustermesh-apiserver (etcd, mTLS-secured)
#   4240/tcp  — Cilium health checks
#   9443/tcp  — Redpanda multicluster operator raft
#   33145/tcp — Redpanda broker RPC
#   9093/tcp  — Kafka client
#   8082/tcp  — Pandaproxy
#   9644/tcp  — Admin API
variable "cross_cloud_tcp_ports" {
  description = "TCP ports allowed inbound on node SG from the other clouds."
  type        = list(number)
  default     = [2379, 4240, 9443, 33145, 9093, 8082, 9644]
}

variable "cross_cloud_udp_ports" {
  description = "UDP ports allowed inbound on node SG from the other clouds."
  type        = list(number)
  default     = [51871, 8472]
}

# BGP ASN for this cloud's VPN gateway. Must be unique across the three
# clouds in the mesh. Default 64512 is the typical Amazon-side ASN.
variable "vpn_aws_asn" {
  description = "BGP ASN for the AWS VPN gateway. Must be distinct from gcp / azure ASNs."
  type        = number
  default     = 64512
}
