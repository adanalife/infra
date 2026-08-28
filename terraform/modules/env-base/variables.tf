# Everything stage-1 and prod-1 provision identically: CI + developer IAM,
# external-dns IAM, Route53 zones, the static site (S3 + CloudFront + ACM),
# RDS, the default VPC, the postgres WAL archive, the ESO reader, and the GCP
# identity/WIF/API set. Env-specific resources belong in the calling root, not
# behind conditionals here.

variable "core_account_id" {
  type        = string
  description = "The AWS account ID for the core account"
}

variable "account_name" {
  type        = string
  description = "Env-scoped account name, e.g. stage-1"
}

variable "full_account_name" {
  type        = string
  description = "Org-prefixed account name, e.g. adanalife-stage-1. Prefixes globally-unique resource names."
}

variable "gcp_project" {
  type        = string
  description = "GCP project ID this environment manages, e.g. tripbot-stage"
}

variable "external_dns_role" {
  type    = string
  default = "ExternalDNSRole"
}

variable "primary_subdomain" {
  type        = string
  description = "Env-scoped primary domain, e.g. stage.dana.lol"
}

variable "secondary_subdomain" {
  type        = string
  description = "Env-scoped secondary domain, e.g. stage.whereisdana.today"
}

variable "static_site_public_dir" {
  description = "Directory in S3 Bucket from which to serve public files (no leading or trailing slashes)"
  type        = string
}

variable "primary_acm_cert_alternative_names" {
  type    = list(string)
  default = []
}

locals {
  primary_static_site = "static.${var.primary_subdomain}"
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# a secret string between CloudFront and S3 to control access
resource "random_password" "static_site_secret" {
  length = 32
}

# Passed straight through to the ci module; see its variables.tf. Empty in an
# env that has not opted into keyless CI auth.
variable "github_oidc_subjects" {
  type        = list(string)
  default     = []
  description = "GitHub Actions OIDC `sub` claims allowed to assume CITerraformRole; empty disables OIDC entirely"
}
