provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project = var.project_name
      Owner   = var.owner
    }
  }
}

# Authenticate the kubernetes provider against the EKS cluster the EKS
# module just created. Uses the `aws eks get-token` exec auth path so we
# don't have to materialize a kubeconfig file. The cluster_endpoint and
# cluster_ca depend on the EKS module, which forces TF to evaluate them
# lazily (provider config is per-graph, not per-resource, so we can't
# directly depend on the module — exec-based auth handles the lazy
# binding correctly).
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", module.eks.cluster_name,
      "--region", var.region,
    ]
  }
}
