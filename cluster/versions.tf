# ─────────────────────────────────────────────────────────────────────────────
#  project-eks/cluster — two EKS clusters (observability + bankobs), each in its
#  own VPC, peered, sharing a private DNS zone for in-cluster telemetry ingest.
#  Provisioned entirely with Terraform. One `terraform apply`.
# ─────────────────────────────────────────────────────────────────────────────
terraform {
  required_version = ">= 1.5"

  # State is kept OUTSIDE the repo (in $HOME — see the Makefile's STATE_FILE) so a re-clone,
  # `git clean`, or checkout can't wipe it. A repo-local terraform.tfstate was lost once, which
  # left `terraform destroy` with an empty state and unable to see/destroy anything. The concrete
  # path is passed at init time via `-backend-config="path=..."`, keeping this block portable.
  backend "local" {}

  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 6.0" }
    helm       = { source = "hashicorp/helm", version = "~> 3.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 3.0" }
    tls        = { source = "hashicorp/tls", version = "~> 4.0" }
    cloudinit  = { source = "hashicorp/cloudinit", version = "~> 2.3" }
  }
}
