# Cloudflare Pages project for the dana.lol production site.
#
# Mirrors stage-1/cloudflare-pages.tf. Prod-1 ships a separate Pages
# project ("dana-lol-production") that serves www.dana.lol once the
# Route53 CNAME is flipped (terraform/core/route53.tf).
#
# DNS authority for dana.lol stays in Route53 — there is no
# cloudflare_zone for dana.lol here, and no cloudflare_dns_record
# partner for the cloudflare_pages_domain below. Cloudflare validates
# the custom-domain TLS cert via the Route53-managed CNAME pointing
# at dana-lol-production.pages.dev.

variable "cloudflare_account_id" {
  type        = string
  description = "Cloudflare account ID"
}

variable "project_name" {
  type        = string
  description = "Cloudflare Pages project name"
}

variable "github_repo_owner" {
  type        = string
  description = "GitHub repository owner for the Pages project"
  default     = "adanalife"
}

variable "github_repo_name" {
  type        = string
  description = "GitHub repository name for the Pages project"
  default     = "website"
}

variable "production_branch" {
  type        = string
  description = "Git branch used for production deployments of the Pages project"
  default     = "master"
}

# Token sourced from AWS Secrets Manager — see secrets.tf for the
# bootstrap flow. Lives here (not providers.tf) so prod-1 doesn't
# inherit a hanging cloudflare provider via the symlinked providers.tf
# from stage-1 (which intentionally omits it).
provider "cloudflare" {
  api_token = data.aws_secretsmanager_secret_version.cloudflare_api_token.secret_string
}

resource "cloudflare_pages_project" "prod_1" {
  account_id = var.cloudflare_account_id
  name       = var.project_name

  production_branch = var.production_branch

  # Build is handled by GitHub Actions (wrangler pages deploy),
  # not by Cloudflare's built-in CI. No build_config needed.

  source = {
    type = "github"
    config = {
      owner                          = var.github_repo_owner
      repo_name                      = var.github_repo_name
      production_branch              = var.production_branch
      preview_deployment_setting     = "custom"
      preview_branch_includes        = ["*"]
      preview_branch_excludes        = [var.production_branch]
      pr_comments_enabled            = true
      production_deployments_enabled = false
    }
  }
}

output "pages_url" {
  description = "Cloudflare Pages URL"
  value       = "${var.project_name}.pages.dev"
}

output "pages_project_name" {
  description = "Cloudflare Pages project name (used by wrangler)"
  value       = cloudflare_pages_project.prod_1.name
}

# Custom domain: bind www.dana.lol to the production Pages project.
# Cloudflare provisions a TLS cert via DNS-01 against the Route53
# CNAME (terraform/core/route53.tf:aws_route53_record.primary_www),
# which targets dana-lol-production.pages.dev. No cloudflare_dns_record
# here because dana.lol's authoritative DNS lives in Route53.
resource "cloudflare_pages_domain" "prod_1_dana_lol_www" {
  account_id   = var.cloudflare_account_id
  project_name = cloudflare_pages_project.prod_1.name
  name         = "www.${var.primary_domain}"
}
