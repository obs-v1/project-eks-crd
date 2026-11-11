# ── EKS: observability cluster ───────────────────────────────────────────────
module "eks_observability" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.obs_cluster_name
  kubernetes_version = var.eks_version

  # Let EKS own the /aws/eks/<name>/cluster log group instead of Terraform. EKS creates it
  # automatically when control-plane logging is on, so a re-apply after a prior/partial run
  # never collides with a leftover group (ResourceAlreadyExistsException). `make destroy`
  # removes it explicitly, since EKS does not delete it on cluster teardown.
  create_cloudwatch_log_group = false

  # Public API so you can kubectl from anywhere; private access on too, for the
  # in-VPC/peered paths.
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.public_api_access_cidrs
  endpoint_private_access      = true

  enable_irsa                              = true
  enable_cluster_creator_admin_permissions = true
  authentication_mode                      = "API_AND_CONFIG_MAP"

  # Grant cluster-admin to any extra principals (e.g. the EC2 instance role running `make apply`).
  access_entries = {
    for arn in var.cluster_admin_arns : arn => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  vpc_id     = module.vpc_observability.vpc_id
  subnet_ids = module.vpc_observability.private_subnets

  # EBS CSI is added separately (addons.tf) to avoid an OIDC dependency cycle.
  addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni    = { most_recent = true, before_compute = true }
  }

  eks_managed_node_groups = {
    spot = {
      instance_types = var.obs_node_instance_types
      capacity_type  = "SPOT"
      min_size       = var.obs_node_scaling.min
      max_size       = var.obs_node_scaling.max
      desired_size   = var.obs_node_scaling.desired
      labels         = { role = "observability" }
      # Pin this node group to ONE AZ. The obs stack is all EBS-backed StatefulSets
      # (Prometheus/Grafana/Loki/Alertmanager/Pyroscope). On a Spot interruption the
      # replacement node can come up in a different AZ than the volume (an EBS volume is
      # stuck in its own AZ), leaving the pod unschedulable — "didn't match
      # PersistentVolume's node affinity" — and the cluster-autoscaler can't fix it
      # ("NotTriggerScaleUp"). Keeping every node and every volume in a single AZ means
      # they can never strand. private_subnets is [AZ0, AZ1, AZ2]; index 0 is the first AZ.
      subnet_ids = [module.vpc_observability.private_subnets[0]]
    }
  }

  tags = local.tags
}

# ── EKS: bankobs cluster ─────────────────────────────────────────────────────
module "eks_bankobs" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.bankobs_cluster_name
  kubernetes_version = var.eks_version

  # Let EKS own the /aws/eks/<name>/cluster log group (see the observability cluster above).
  create_cloudwatch_log_group = false

  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.public_api_access_cidrs
  endpoint_private_access      = true

  enable_irsa                              = true
  enable_cluster_creator_admin_permissions = true
  authentication_mode                      = "API_AND_CONFIG_MAP"

  # Grant cluster-admin to any extra principals (e.g. the EC2 instance role running `make apply`).
  access_entries = {
    for arn in var.cluster_admin_arns : arn => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  vpc_id     = module.vpc_bankobs.vpc_id
  subnet_ids = module.vpc_bankobs.private_subnets

  addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni    = { most_recent = true, before_compute = true }
  }

  eks_managed_node_groups = {
    spot = {
      instance_types = var.bankobs_node_instance_types
      capacity_type  = "SPOT"
      min_size       = var.bankobs_node_scaling.min
      max_size       = var.bankobs_node_scaling.max
      desired_size   = var.bankobs_node_scaling.desired
      labels         = { role = "bankobs" }
      # Pin to ONE AZ for the same reason as the observability node group above: bankobs
      # runs EBS-backed StatefulSets (Kafka, Oracle, Cassandra, Postgres, Mongo, …). A
      # Spot reschedule into another AZ strands them — e.g. Kafka came back with an empty
      # data dir and every `banking.*` topic gone, so services hung producing events.
      # Single-AZ keeps nodes and volumes co-located. index 0 = the first AZ.
      subnet_ids = [module.vpc_bankobs.private_subnets[0]]
    }
  }

  tags = local.tags
}
