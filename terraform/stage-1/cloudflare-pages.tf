# Cloudflare Pages project for dana.lol static site
#
# Staging-first: this creates "dana-lol-staging" on Cloudflare Pages.
# The site will be available at dana-lol-staging.pages.dev.
# PR preview deployments are automatic for any non-production branch.
#
# TODO: once staging is verified, add a "dana-lol" production project
# alongside this one (in terraform/prod-1/) and update Route53
# www.dana.lol CNAME to point to it.

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
# bootstrap flow. Lives here (not providers.tf) so prod-1's symlink
# to providers.tf doesn't inherit a provider it has no resources for.
provider "cloudflare" {
  api_token = data.aws_secretsmanager_secret_version.cloudflare_api_token.secret_string
}

resource "cloudflare_pages_project" "stage_1" {
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
  value       = cloudflare_pages_project.stage_1.name
}

# Custom domain: bind www.whalecore.com to the staging Pages project so
# the staging site is reachable at a real hostname (handy for sharing
# previews and for testing flows that depend on a non-pages.dev origin).
# The matching DNS record is below.
resource "cloudflare_pages_domain" "stage_1_whalecore_www" {
  account_id   = var.cloudflare_account_id
  project_name = cloudflare_pages_project.stage_1.name
  name         = "www.${cloudflare_zone.stage_1.name}"
}

# Orange-cloud CNAME so www.whalecore.com resolves through Cloudflare's
# edge and Universal SSL fronts the Pages origin. Pages requires the
# proxy on for custom-domain TLS to work.
resource "cloudflare_dns_record" "stage_1_whalecore_www_pages" {
  zone_id = cloudflare_zone.stage_1.id
  name    = "www"
  type    = "CNAME"
  ttl     = 1 # 1 = auto when proxied
  proxied = true
  content = "${cloudflare_pages_project.stage_1.name}.pages.dev"
}
