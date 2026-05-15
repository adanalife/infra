# KEEP-IN-SYNC: terraform/{stage-1,prod-1}/variables.tf
#
# De-symlinked 2026-05-11. Stage-1 and prod-1 are intentionally near-identical
# until the modules refactor lands (vault/infra/TODO.md). Any structural
# change here SHOULD be mirrored to the sibling file unless the divergence
# is the whole point of the change.

# prod, stage, dev
variable "environment" {
  type = string
}

variable "label" {
  type        = string
  description = "An identifier for this particular environment"
  default     = "1"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "core_account_id" {
  type        = string
  description = "The AWS account ID for the core account"
}

variable "primary_domain" {
  type        = string
  description = "The domain name used for DNS"
}

variable "secondary_domain" {
  type        = string
  description = "The domain name used for secondary DNS"
}

variable "external_dns_role" {
  type    = string
  default = "ExternalDNSRole"
}


variable "static_site_public_dir" {
  description = "Directory in S3 Bucket from which to serve public files (no leading or trailing slashes)"
  type        = string
}

variable "primary_acm_cert_alternative_names" {
  type    = list(string)
  default = []
}

# Cloudflare-related variables live in cloudflare-pages.tf so that
# prod-1 (which symlinks this file) doesn't see them as required
# inputs without having any cloudflare resources to use them on.

# a secret string between CloudFront and S3 to control access
resource "random_password" "static_site_secret" {
  length = 32
}

locals {
  org_name = "adanalife"
  # this is how we will refer to the account in other places
  account_name        = "${var.environment}-${var.label}"
  full_account_name   = "${local.org_name}-${var.environment}-${var.label}"
  primary_subdomain   = "${var.environment}.${var.primary_domain}"
  secondary_subdomain = "${var.environment}.${var.secondary_domain}"
  primary_static_site = "static.${local.primary_subdomain}"
}
