# Cloudflare Pages project for dana.lol static site
#
# This creates "dana-lol-staging" on Cloudflare Pages, available at
# dana-lol-staging.pages.dev. PR preview deployments are automatic for any
# non-production branch. The production project lives in terraform/prod-1/.

variable "cloudflare_account_id" {
  type        = string
  description = "Cloudflare account ID"
}

variable "project_name" {
  type        = string
  description = "Cloudflare Pages project name"
}

variable "production_branch" {
  type        = string
  description = "Git branch used for production deployments of the Pages project"
  default     = "main"
}

# Token sourced from AWS Secrets Manager — see secrets.tf for the
# bootstrap flow. Lives here (not providers.tf) so prod-1's symlink
# to providers.tf doesn't inherit a provider it has no resources for.
provider "cloudflare" {
  api_token = data.aws_ssm_parameter.cloudflare_api_token.value
}

module "pages" {
  source = "../modules/cloudflare-pages-project"

  account_id        = var.cloudflare_account_id
  project_name      = var.project_name
  production_branch = var.production_branch

  domains = [
    # A real hostname for the staging site, handy for sharing previews and for
    # testing flows that depend on a non-pages.dev origin. Cloudflare is
    # authoritative for this zone, hence the proxied CNAME below.
    "www.${cloudflare_zone.stage_1.name}",
    # Authoritative DNS for dana.lol lives in Route53, so there is no
    # cloudflare_dns_record partner for this one — the matching CNAME is
    # terraform/core/route53.tf:aws_route53_record.primary_staging, and
    # Cloudflare validates the TLS cert through it.
    "staging.dana.lol",
  ]

  dns_record = {
    zone_id = cloudflare_zone.stage_1.id
    name    = "www"
  }
}

moved {
  from = cloudflare_pages_project.stage_1
  to   = module.pages.cloudflare_pages_project.this
}

moved {
  from = cloudflare_pages_domain.stage_1_whalecore_www
  to   = module.pages.cloudflare_pages_domain.this["www.whalecore.com"]
}

moved {
  from = cloudflare_pages_domain.stage_1_staging_dana_lol
  to   = module.pages.cloudflare_pages_domain.this["staging.dana.lol"]
}

moved {
  from = cloudflare_dns_record.stage_1_whalecore_www_pages
  to   = module.pages.cloudflare_dns_record.this[0]
}

output "pages_url" {
  description = "Cloudflare Pages URL"
  value       = module.pages.pages_url
}

output "pages_project_name" {
  description = "Cloudflare Pages project name (used by wrangler)"
  value       = module.pages.project_name
}
