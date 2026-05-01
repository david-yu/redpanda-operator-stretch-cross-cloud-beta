module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  vpc_id = module.vpc.vpc_id
  # Nodes go in PUBLIC subnets so they're directly reachable from the other
  # clouds without VPN — required for Cilium clustermesh node-to-node.
  subnet_ids = module.vpc.public_subnets

  cluster_endpoint_public_access = true

  # Service CIDR Cilium's kubeProxyReplacement will see and use for ClusterIP
  # routing.
  cluster_service_ipv4_cidr = var.service_cidr

  # IMPORTANT: do NOT enable the `vpc-cni` addon. EKS will start the cluster
  # without a CNI and nodes will report NotReady until Cilium is installed.
  # We also skip `kube-proxy` because Cilium replaces it with eBPF
  # (kubeProxyReplacement=true). `coredns` is fine — it just sits Pending
  # on a NotReady node until Cilium provides networking, then becomes Ready.
  cluster_addons = {
    coredns = {
      most_recent = true
      # CoreDNS won't schedule until at least one node is Ready, which
      # requires Cilium. Skip the addon's wait so terraform apply finishes
      # while you go install Cilium.
      configuration_values = jsonencode({
        tolerations = [{
          key      = "node.kubernetes.io/not-ready"
          operator = "Exists"
          effect   = "NoSchedule"
        }]
      })
    }
  }

  eks_managed_node_groups = {
    default = {
      desired_size = var.node_count
      min_size     = var.node_count
      max_size     = var.node_count + 1

      instance_types = [var.node_instance_type]

      # Public subnets so the node ENIs auto-assign public IPs.
      subnet_ids = module.vpc.public_subnets

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.node_volume_size_gb
            volume_type           = "gp3"
            delete_on_termination = true
            encrypted             = true
          }
        }
      }

      # Until Cilium is installed, kubelet reports NotReady. Tolerate that
      # so the node group's lifecycle hooks don't fail.
      taints = []
    }
  }

  enable_cluster_creator_admin_permissions = true
}

# Allow the cross-cloud ports inbound on the node SG. Open to 0.0.0.0/0
# because the other clouds' node IPs aren't predictable; tighten to known
# CIDR blocks in production.
resource "aws_security_group_rule" "cross_cloud_tcp" {
  for_each          = toset([for p in var.cross_cloud_tcp_ports : tostring(p)])
  type              = "ingress"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = module.eks.node_security_group_id
  description       = "cross-cloud cilium clustermesh / redpanda tcp/${each.value}"
}

resource "aws_security_group_rule" "cross_cloud_udp" {
  for_each          = toset([for p in var.cross_cloud_udp_ports : tostring(p)])
  type              = "ingress"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  protocol          = "udp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = module.eks.node_security_group_id
  description       = "cross-cloud cilium wireguard/vxlan udp/${each.value}"
}
