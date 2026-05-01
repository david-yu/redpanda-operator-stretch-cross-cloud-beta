data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  # Public subnets host worker nodes that need direct internet for Cilium
  # cross-cloud node-to-node encryption (WireGuard). Auto-assigned public
  # IPs make node-to-node reachability trivial without a NAT mesh.
  public_subnets  = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnets = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i + 8)]
}
