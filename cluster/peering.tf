# ── VPC peering: bankobs ⇄ observability ─────────────────────────────────────
# Same account/region, so the peering auto-accepts. This is what makes the
# private collector endpoint actually ROUTE (the shared private zone only makes
# the name RESOLVE).
resource "aws_vpc_peering_connection" "obs_bankobs" {
  vpc_id      = module.vpc_bankobs.vpc_id
  peer_vpc_id = module.vpc_observability.vpc_id
  auto_accept = true

  tags = merge(local.tags, { Name = "${var.project}-bankobs-to-observability" })
}

# Routes: each VPC's private route tables get a path to the other's CIDR via the peering.
resource "aws_route" "bankobs_to_obs" {
  count                     = length(module.vpc_bankobs.private_route_table_ids)
  route_table_id            = module.vpc_bankobs.private_route_table_ids[count.index]
  destination_cidr_block    = var.obs_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.obs_bankobs.id
}

resource "aws_route" "obs_to_bankobs" {
  count                     = length(module.vpc_observability.private_route_table_ids)
  route_table_id            = module.vpc_observability.private_route_table_ids[count.index]
  destination_cidr_block    = var.bankobs_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.obs_bankobs.id
}

# Let the observability nodes accept OTLP (gRPC 4317 / HTTP 4318) from the bankobs CIDR.
resource "aws_security_group_rule" "obs_nodes_allow_otlp_from_bankobs" {
  type              = "ingress"
  description       = "OTLP ingest from the bankobs VPC (private, over peering)"
  security_group_id = module.eks_observability.node_security_group_id
  from_port         = 4317
  to_port           = 4318
  protocol          = "tcp"
  cidr_blocks       = [var.bankobs_vpc_cidr]
}
