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

  # NOTE: we'd love to set `bootstrap_self_managed_addons = false` here so
  # EKS doesn't install aws-node automatically. Unfortunately the EKS
  # managed node group has a built-in health check (~15 min timeout)
  # waiting for nodes to be Ready, and without aws-node + kube-proxy
  # nodes can't become Ready, so the node group create fails. Workaround:
  # let EKS install aws-node, then delete the daemonset before Cilium
  # install (the install-cilium.sh script handles this).

  # IMPORTANT: do NOT enable the `vpc-cni` addon. EKS will start the cluster
  # without a CNI and nodes will report NotReady until Cilium is installed.
  # We also skip `kube-proxy` because Cilium replaces it with eBPF
  # (kubeProxyReplacement=true). `coredns` is fine — it just sits Pending
  # on a NotReady node until Cilium provides networking, then becomes Ready.
  #
  # `aws-ebs-csi-driver` IS required: EKS 1.34 removed the in-tree
  # `kubernetes.io/aws-ebs` provisioner, so without the CSI driver, the
  # operator's `gp2`/`gp3` PVC requests for broker `datadir-*` volumes
  # never bind and broker pods sit in `Pending` with
  # `pod has unbound immediate PersistentVolumeClaims`. The driver also
  # needs `AmazonEBSCSIDriverPolicy` attached to the node IAM role
  # (see `iam_role_additional_policies` on the node group below) so its
  # controller can call EC2 EBS APIs from a node-bound IRSA path.
  # Documented as gotcha #11 from the 2026-05-01 validation pass.
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
    aws-ebs-csi-driver = {
      most_recent              = true
      resolve_conflicts_on_update = "OVERWRITE"
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

      # Required by the `aws-ebs-csi-driver` cluster addon above. Without
      # this policy, the CSI driver pods can't call ec2:CreateVolume /
      # AttachVolume from the node and PVC binding silently fails for
      # broker StatefulSets.
      iam_role_additional_policies = {
        AmazonEBSCSIDriverPolicy = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
      }
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

# Allow ALL traffic (incl. ICMP) from peer cloud CIDRs that arrive via
# the VPN. Keeps the cross-cloud ping path open for k8s-style health
# checks and Cilium's underlay tunnel traffic.
resource "aws_security_group_rule" "peer_cloud_all" {
  for_each          = toset(var.peer_cloud_cidrs)
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = [each.value]
  security_group_id = module.eks.node_security_group_id
  description       = "all from peer cloud CIDR (VPN-routed) ${each.value}"
}

# CSI-backed default StorageClass. Required because EKS' bundled `gp2`
# class still references the in-tree `kubernetes.io/aws-ebs` provisioner
# which was removed in 1.34, and the aws-ebs-csi-driver addon doesn't
# install its own default class. Without this, broker PVCs (issued by
# the operator without an explicit storageClassName) sit Pending forever
# with `no persistent volumes available for this claim and no storage
# class is set`. Drift caught during 2026-05-03 e2e validation; was a
# manual `kubectl apply` step before this got codified.
#
# `WaitForFirstConsumer` matches the EKS-default gp2 binding mode so
# pods get a volume in the same AZ as the pod is scheduled to.
resource "kubernetes_storage_class_v1" "ebs_sc" {
  metadata {
    name = "ebs-sc"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  # Force ordering: the aws-ebs-csi-driver addon must be reconciled before
  # this SC is applied, otherwise the provisioner has no controller and
  # the first PVC binding hangs. The addon is keyed under the EKS module's
  # cluster_addons map, so we depend on the module as a whole.
  depends_on = [module.eks]
}

# Allow ALL traffic from the node SG to itself. The terraform-aws-modules/eks
# v20 module's default node SG only opens TCP 1025-65535 + DNS from self —
# which is enough for kubelet/CoreDNS but BLOCKS ICMP and other in-VPC pod
# traffic between nodes. Without this rule, hostNetwork ping between nodes
# fails, and (more subtly) anything that depends on it — e.g. Cilium agents
# falling back to ICMP for liveness, eBPF service-to-pod paths that DNAT
# but don't catch the inverse — silently breaks. Intra-cluster pod-to-pod
# over Geneve UDP/8472 is allowed via the cross_cloud_udp rule above
# (0.0.0.0/0), but tooling that pings intra-cluster won't work without this.
resource "aws_security_group_rule" "node_self_all" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = module.eks.node_security_group_id
  security_group_id        = module.eks.node_security_group_id
  description              = "all intra-cluster traffic (node-to-node ICMP, etc.)"
}
