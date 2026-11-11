provider "aws" {
  region = var.aws_region
  default_tags { tags = local.tags }
}

# Two clusters → two aliased kubernetes/helm providers, each authenticated with a
# short-lived token from `aws eks get-token` (nothing sensitive lands in state).

provider "kubernetes" {
  alias                  = "observability"
  host                   = module.eks_observability.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_observability.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks_observability.cluster_name, "--region", var.aws_region]
  }
}

provider "helm" {
  alias = "observability"
  # helm provider 3.x: `kubernetes` is a nested attribute (was a block), and `exec` with it.
  kubernetes = {
    host                   = module.eks_observability.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_observability.cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks_observability.cluster_name, "--region", var.aws_region]
    }
  }
}

provider "kubernetes" {
  alias                  = "bankobs"
  host                   = module.eks_bankobs.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_bankobs.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks_bankobs.cluster_name, "--region", var.aws_region]
  }
}

provider "helm" {
  alias = "bankobs"
  kubernetes = {
    host                   = module.eks_bankobs.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_bankobs.cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks_bankobs.cluster_name, "--region", var.aws_region]
    }
  }
}
