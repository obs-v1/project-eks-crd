output "region" {
  value = var.aws_region
}

output "observability_cluster_name" {
  value = module.eks_observability.cluster_name
}

# Stored in state so `make destroy` can clean external-dns records out of the public zone
# even when ZONE_ID isn't passed on the destroy command.
output "public_hosted_zone_id" {
  value = var.public_hosted_zone_id
}

output "bankobs_cluster_name" {
  value = module.eks_bankobs.cluster_name
}

output "observability_kubeconfig_command" {
  description = "Run this to point kubectl at the observability cluster."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks_observability.cluster_name} --alias ${module.eks_observability.cluster_name}"
}

output "bankobs_kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks_bankobs.cluster_name} --alias ${module.eks_bankobs.cluster_name}"
}

output "collector_otlp_endpoint" {
  description = "Private OTLP endpoint BankObs sends telemetry to (resolves in both VPCs over the peering)."
  value       = "http://${local.collector_fqdn}:4317"
}

output "collector_fqdn" {
  value = local.collector_fqdn
}

output "private_dns_domain" {
  value = var.private_dns_domain
}

output "public_domain_name" {
  value = var.public_domain_name
}

output "observability_vpc_id" {
  value = module.vpc_observability.vpc_id
}

output "bankobs_vpc_id" {
  value = module.vpc_bankobs.vpc_id
}

output "vpc_peering_connection_id" {
  value = aws_vpc_peering_connection.obs_bankobs.id
}
