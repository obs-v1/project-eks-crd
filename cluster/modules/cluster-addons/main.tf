# ── EBS CSI driver (managed addon, IRSA) + gp3 default StorageClass ──────────
resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = var.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = var.ebs_csi_role_arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = var.tags
}

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    type   = "gp3"
    fsType = "ext4"
    # Stamp every provisioned volume with the cluster name so `make destroy` can find and
    # delete the ones left "available" after the cluster is gone (dynamically-provisioned
    # PV volumes are not Terraform-managed, and EBS is AZ- not VPC-scoped, so this tag is
    # the only safe way to scope the cleanup to just this cluster's volumes).
    tagSpecification_1 = "ebs-owner-cluster=${var.cluster_name}"
  }
  depends_on = [aws_eks_addon.ebs_csi]
}

# ── Cluster Autoscaler ───────────────────────────────────────────────────────
# helm provider 3.x: `set` is a list attribute, not repeated blocks.
resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = "9.59.0"
  namespace  = "kube-system"

  set = [
    { name = "autoDiscovery.clusterName", value = var.cluster_name },
    { name = "awsRegion", value = var.region },
    { name = "rbac.serviceAccount.name", value = "cluster-autoscaler" },
    { name = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn", value = var.autoscaler_role_arn },
    { name = "extraArgs.balance-similar-node-groups", value = "true" },
    { name = "extraArgs.skip-nodes-with-system-pods", value = "false" },
  ]
}

# ── external-dns (ingress + service sources; public UIs + private collector) ──
resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns"
  chart      = "external-dns"
  version    = "1.23.0"
  namespace  = "kube-system"

  set = concat([
    { name = "provider.name", value = "aws" },
    { name = "serviceAccount.name", value = "external-dns" },
    { name = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn", value = var.external_dns_role_arn },
    { name = "policy", value = "upsert-only" }, # never delete records it didn't create; safe in a shared zone
    { name = "txtOwnerId", value = var.cluster_name },
    { name = "sources[0]", value = "ingress" },
    { name = "sources[1]", value = "service" },
    ], [
    for i, d in var.external_dns_domain_filters : { name = "domainFilters[${i}]", value = d }
  ])
}

# ── Traefik ingress controller (public NLB, TLS terminated at the NLB via ACM) ─
resource "helm_release" "traefik" {
  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = "42.2.0"
  namespace        = "traefik"
  create_namespace = true

  values = [yamlencode({
    service = {
      type = "LoadBalancer"
      annotations = {
        "service.beta.kubernetes.io/aws-load-balancer-type"             = "nlb"
        "service.beta.kubernetes.io/aws-load-balancer-scheme"           = "internet-facing"
        "service.beta.kubernetes.io/aws-load-balancer-ssl-cert"         = var.acm_certificate_arn
        "service.beta.kubernetes.io/aws-load-balancer-ssl-ports"        = "websecure"
        "service.beta.kubernetes.io/aws-load-balancer-backend-protocol" = "tcp"
      }
    }
    # TLS is terminated at the NLB (ACM), so Traefik itself serves plain HTTP on
    # both entrypoints — the NLB forwards decrypted traffic to websecure.
    ports = {
      web = {
        port        = 8000
        exposedPort = 80
      }
      websecure = {
        port        = 8443
        exposedPort = 443
        # traefik 42: TLS on an entrypoint lives under http.tls (was ports.websecure.tls).
        # Disabled because the NLB terminates TLS (ACM) and forwards plain HTTP.
        http = { tls = { enabled = false } }
      }
    }
    # Redirect all plain HTTP (:80 → web entrypoint) to HTTPS. We target ":443" explicitly
    # rather than the websecure entrypoint, because TLS terminates at the NLB: Traefik's
    # websecure entrypoint listens on 8443 internally, so a redirect "to websecure" would
    # emit https://host:8443. ":443" makes the Location a clean https://host (443 = default).
    additionalArguments = [
      "--entrypoints.web.http.redirections.entrypoint.to=:443",
      "--entrypoints.web.http.redirections.entrypoint.scheme=https",
      "--entrypoints.web.http.redirections.entrypoint.permanent=true",
    ]
    ingressClass = {
      enabled        = true
      isDefaultClass = true
    }
    # Publish Traefik's LB address onto each Ingress's status, so external-dns
    # (source=ingress) can create the DNS records pointing at the NLB.
    providers = {
      kubernetesIngress = {
        publishedService = {
          enabled = true
        }
      }
    }
  })]
}
