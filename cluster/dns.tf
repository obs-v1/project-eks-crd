# ── Private DNS zone shared by both VPCs ─────────────────────────────────────
# Associated with BOTH VPCs so a name like otel-collector.obs.internal resolves
# from either cluster. external-dns (running in the observability cluster) writes
# the actual record when the internal Collector LoadBalancer comes up.
resource "aws_route53_zone" "private" {
  name = var.private_dns_domain

  # external-dns writes an otel-collector.<domain> record in here that it never deletes
  # (it runs --policy=upsert-only), so without this `terraform destroy` fails on the zone
  # with HostedZoneNotEmpty. force_destroy lets Terraform purge the records first.
  force_destroy = true

  vpc {
    vpc_id = module.vpc_observability.vpc_id
  }
  vpc {
    vpc_id = module.vpc_bankobs.vpc_id
  }

  # external-dns manages records in here; ignore drift on the association set.
  lifecycle {
    ignore_changes = [vpc]
  }

  tags = merge(local.tags, { Name = "${var.project}-private" })
}
