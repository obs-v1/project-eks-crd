# ── Addons on the observability cluster ──────────────────────────────────────
module "addons_observability" {
  source = "./modules/cluster-addons"

  providers = {
    helm       = helm.observability
    kubernetes = kubernetes.observability
  }

  cluster_name          = module.eks_observability.cluster_name
  region                = var.aws_region
  ebs_csi_role_arn      = module.irsa_obs_ebs_csi.arn
  external_dns_role_arn = module.irsa_obs_external_dns.arn
  autoscaler_role_arn   = module.irsa_obs_autoscaler.arn
  # obs manages the public UI domain AND the private collector domain
  external_dns_domain_filters = [var.public_domain_name, var.private_dns_domain]
  acm_certificate_arn         = var.acm_certificate_arn
  tags                        = local.tags
}

# ── Addons on the bankobs cluster ────────────────────────────────────────────
module "addons_bankobs" {
  source = "./modules/cluster-addons"

  providers = {
    helm       = helm.bankobs
    kubernetes = kubernetes.bankobs
  }

  cluster_name                = module.eks_bankobs.cluster_name
  region                      = var.aws_region
  ebs_csi_role_arn            = module.irsa_bankobs_ebs_csi.arn
  external_dns_role_arn       = module.irsa_bankobs_external_dns.arn
  autoscaler_role_arn         = module.irsa_bankobs_autoscaler.arn
  external_dns_domain_filters = [var.public_domain_name] # only bankobs.<domain>
  acm_certificate_arn         = var.acm_certificate_arn
  tags                        = local.tags
}

# ── Cluster-autoscaler ASG discovery tags ────────────────────────────────────
# Managed node group ASGs are not auto-tagged for CA discovery, so tag them.
# An EKS managed node group is always exactly ONE ASG, so we reference [0] directly.
# (A for_each over these names fails to plan on a fresh apply — the names are only
#  known after the clusters exist; an unknown attribute VALUE is fine, unknown keys aren't.)
locals {
  obs_asg_name     = module.eks_observability.eks_managed_node_groups_autoscaling_group_names[0]
  bankobs_asg_name = module.eks_bankobs.eks_managed_node_groups_autoscaling_group_names[0]
}

resource "aws_autoscaling_group_tag" "obs_ca_enabled" {
  autoscaling_group_name = local.obs_asg_name
  tag {
    key                 = "k8s.io/cluster-autoscaler/enabled"
    value               = "true"
    propagate_at_launch = false
  }
}

resource "aws_autoscaling_group_tag" "obs_ca_cluster" {
  autoscaling_group_name = local.obs_asg_name
  tag {
    key                 = "k8s.io/cluster-autoscaler/${local.obs_cluster_name}"
    value               = "owned"
    propagate_at_launch = false
  }
}

resource "aws_autoscaling_group_tag" "bankobs_ca_enabled" {
  autoscaling_group_name = local.bankobs_asg_name
  tag {
    key                 = "k8s.io/cluster-autoscaler/enabled"
    value               = "true"
    propagate_at_launch = false
  }
}

resource "aws_autoscaling_group_tag" "bankobs_ca_cluster" {
  autoscaling_group_name = local.bankobs_asg_name
  tag {
    key                 = "k8s.io/cluster-autoscaler/${local.bankobs_cluster_name}"
    value               = "owned"
    propagate_at_launch = false
  }
}
