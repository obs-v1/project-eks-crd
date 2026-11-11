locals {
  obs_cluster_name     = "${var.project}-observability"
  bankobs_cluster_name = "${var.project}-bankobs"

  # Stable private name BankObs uses to reach the observability Collector across
  # the VPC peering. external-dns (obs cluster) publishes this into the private zone.
  collector_fqdn = "otel-collector.${var.private_dns_domain}"

  tags = merge({
    Project   = var.project
    ManagedBy = "terraform"
    Repo      = "project-eks/cluster"
  }, var.tags)
}
