variable "project_name" {
  description = "Tag value for cost allocation / cleanup."
  type        = string
  default     = "redpanda-stretch-cross-cloud"
}

variable "region" {
  description = "Azure region. Pick one with low RTT to your AWS and GCP regions — eastus (Virginia) pairs well with AWS us-east-1 and GCP us-east1 (~5-15ms cross-cloud)."
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Resource group name."
  type        = string
  default     = "rp-aws-cross-cloud"
}

variable "cluster_name" {
  description = "Name of the AKS cluster (also the kubectl context alias)."
  type        = string
  default     = "rp-azure"
}

variable "kubernetes_version" {
  description = "AKS Kubernetes version. Must be one of `az aks get-versions --location <region>` (Azure rotates LTS-only minors faster than other clouds — bump if apply fails). Cilium 1.16+ supports K8s 1.27 through 1.34."
  type        = string
  default     = "1.34"
}

variable "vnet_cidr" {
  description = "VNet CIDR. Must NOT overlap the AWS / GCP VPC CIDRs (defaults 10.10/16, 10.20/16)."
  type        = string
  default     = "10.30.0.0/16"
}

variable "subnet_cidr" {
  description = "Node subnet CIDR (within vnet_cidr)."
  type        = string
  default     = "10.30.0.0/20"
}

variable "pod_cidr" {
  description = "Pod CIDR Cilium will hand out from. Must NOT overlap the other clusters' pod CIDRs (defaults 10.110/16 AWS, 10.120/16 GCP, 10.130/16 here)."
  type        = string
  default     = "10.130.0.0/16"
}

variable "service_cidr" {
  description = "Service CIDR for AKS. Configured on the AKS network_profile."
  type        = string
  default     = "10.131.0.0/20"
}

variable "dns_service_ip" {
  description = "DNS service IP — must sit inside service_cidr."
  type        = string
  default     = "10.131.0.10"
}

variable "vm_size" {
  description = "VM size for the AKS node pool."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "node_count" {
  description = "Node count for the default pool. 2 fits the typical 10 vCPU regional sandbox quota for the DSv5 family (2× Standard_D4s_v5 = 8 vCPU)."
  type        = number
  default     = 2
}

variable "node_disk_size_gb" {
  description = "OS disk size for each node (GiB)."
  type        = number
  default     = 50
}

variable "cross_cloud_tcp_ports" {
  description = "TCP ports allowed inbound from other clouds (Cilium clustermesh-apiserver, health, Redpanda)."
  type        = list(number)
  default     = [2379, 4240, 9443, 33145, 9093, 8082, 9644]
}

variable "cross_cloud_udp_ports" {
  description = "UDP ports allowed inbound (Cilium WireGuard / VXLAN)."
  type        = list(number)
  default     = [51871, 8472]
}

variable "gateway_subnet_cidr" {
  description = "CIDR for the VPN Gateway's reserved 'GatewaySubnet' (Azure mandates that exact subnet name). Must be inside vnet_cidr and not overlap subnet_cidr."
  type        = string
  default     = "10.30.255.0/27"
}

variable "vpn_azure_asn" {
  description = "BGP ASN for the Azure VPN Gateway. Must be distinct from aws / gcp ASNs."
  type        = number
  default     = 64514
}
