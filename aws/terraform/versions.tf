terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    # Used to install a CSI-backed default StorageClass (`ebs-sc`) right
    # after the cluster + EBS CSI driver addon come up. Without it, the
    # EKS-default `gp2` StorageClass uses the in-tree
    # `kubernetes.io/aws-ebs` provisioner (removed in 1.34) and broker
    # PVCs sit Pending forever — gotcha #11 / 2026-05-03 finding.
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }
}
