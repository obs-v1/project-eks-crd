locals {
  public_zone_arn  = "arn:aws:route53:::hostedzone/${var.public_hosted_zone_id}"
  private_zone_arn = "arn:aws:route53:::hostedzone/${aws_route53_zone.private.zone_id}"
}

# ── Observability cluster IRSA roles ─────────────────────────────────────────
module "irsa_obs_ebs_csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name                  = "${local.obs_cluster_name}-ebs-csi"
  policy_name           = "${local.obs_cluster_name}-ebs-csi"
  use_name_prefix       = false
  attach_ebs_csi_policy = true
  oidc_providers = {
    main = {
      provider_arn               = module.eks_observability.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
  tags = local.tags
}

module "irsa_obs_external_dns" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name                          = "${local.obs_cluster_name}-external-dns"
  policy_name                   = "${local.obs_cluster_name}-external-dns"
  use_name_prefix               = false
  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = [local.public_zone_arn, local.private_zone_arn] # UIs + private collector
  oidc_providers = {
    main = {
      provider_arn               = module.eks_observability.oidc_provider_arn
      namespace_service_accounts = ["kube-system:external-dns"]
    }
  }
  tags = local.tags
}

module "irsa_obs_autoscaler" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name                             = "${local.obs_cluster_name}-cluster-autoscaler"
  policy_name                      = "${local.obs_cluster_name}-cluster-autoscaler"
  use_name_prefix                  = false
  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_names = [local.obs_cluster_name]
  oidc_providers = {
    main = {
      provider_arn               = module.eks_observability.oidc_provider_arn
      namespace_service_accounts = ["kube-system:cluster-autoscaler"]
    }
  }
  tags = local.tags
}

# ── BankObs cluster IRSA roles ───────────────────────────────────────────────
module "irsa_bankobs_ebs_csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name                  = "${local.bankobs_cluster_name}-ebs-csi"
  policy_name           = "${local.bankobs_cluster_name}-ebs-csi"
  use_name_prefix       = false
  attach_ebs_csi_policy = true
  oidc_providers = {
    main = {
      provider_arn               = module.eks_bankobs.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
  tags = local.tags
}

module "irsa_bankobs_external_dns" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name                          = "${local.bankobs_cluster_name}-external-dns"
  policy_name                   = "${local.bankobs_cluster_name}-external-dns"
  use_name_prefix               = false
  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = [local.public_zone_arn] # bankobs.<domain> only
  oidc_providers = {
    main = {
      provider_arn               = module.eks_bankobs.oidc_provider_arn
      namespace_service_accounts = ["kube-system:external-dns"]
    }
  }
  tags = local.tags
}

module "irsa_bankobs_autoscaler" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name                             = "${local.bankobs_cluster_name}-cluster-autoscaler"
  policy_name                      = "${local.bankobs_cluster_name}-cluster-autoscaler"
  use_name_prefix                  = false
  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_names = [local.bankobs_cluster_name]
  oidc_providers = {
    main = {
      provider_arn               = module.eks_bankobs.oidc_provider_arn
      namespace_service_accounts = ["kube-system:cluster-autoscaler"]
    }
  }
  tags = local.tags
}
