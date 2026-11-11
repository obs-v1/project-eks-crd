variable "cluster_name" { type = string }
variable "region" { type = string }

variable "ebs_csi_role_arn" { type = string }
variable "external_dns_role_arn" { type = string }
variable "autoscaler_role_arn" { type = string }

variable "external_dns_domain_filters" {
  description = "Domains external-dns is allowed to manage in this cluster (public, + private for obs)."
  type        = list(string)
}

variable "acm_certificate_arn" {
  description = "ACM cert for the public Traefik NLB (TLS terminated at the NLB)."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
