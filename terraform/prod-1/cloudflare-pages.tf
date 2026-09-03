# Cloudflare Pages project for the dana.lol production site.
#
# Mirrors stage-1/cloudflare-pages.tf. Prod-1 ships a separate Pages
# project ("dana-lol-production") that serves www.dana.lol once the
# Route53 CNAME is flipped (terraform/core/route53.tf).
#
# DNS authority for dana.lol stays in Route53 — there is no
# cloudflare_zone for dana.lol here, and no cloudflare_dns_record
# partner for the custom domain below. Cloudflare validates the
# custom-domain TLS cert via the Route53-managed CNAME pointing
# at dana-lol-production.pages.dev.

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
# bootstrap flow. Lives here (not providers.tf) so prod-1 doesn't
# inherit a hanging cloudflare provider via the symlinked providers.tf
# from stage-1 (which intentionally omits it).
provider "cloudflare" {
  api_token = data.aws_ssm_parameter.cloudflare_api_token.value
}

module "pages" {
  source = "../modules/cloudflare-pages-project"

  account_id        = var.cloudflare_account_id
  project_name      = var.project_name
  production_branch = var.production_branch

  # Cloudflare provisions the TLS cert via DNS-01 against the Route53 CNAME
  # (terraform/core/route53.tf:aws_route53_record.primary_www), which targets
  # dana-lol-production.pages.dev.
  domains = ["www.${var.primary_domain}"]
}

moved {
  from = cloudflare_pages_project.prod_1
  to   = module.pages.cloudflare_pages_project.this
}

moved {
  from = cloudflare_pages_domain.prod_1_dana_lol_www
  to   = module.pages.cloudflare_pages_domain.this["www.dana.lol"]
}

output "pages_url" {
  description = "Cloudflare Pages URL"
  value       = module.pages.pages_url
}

output "pages_project_name" {
  description = "Cloudflare Pages project name (used by wrangler)"
  value       = module.pages.project_name
}
