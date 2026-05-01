module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.cluster_name
  cidr = var.vpc_cidr

  azs             = local.azs
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  # Single NAT for the demo (private subnets aren't used for nodes here, but
  # keeping NAT helps if you later move nodes to private subnets behind VPN).
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Auto-assign public IPs so EKS nodes are directly reachable from the
  # other clouds' nodes (Cilium WireGuard node-to-node).
  map_public_ip_on_launch = true

  # EKS subnet tags so the in-tree LB provider picks the right subnet for
  # the Cilium clustermesh-apiserver Service of type=LoadBalancer.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}
