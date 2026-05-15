# Cloudflare Pages project for dana.lol static site
#
# Staging-first: this creates "dana-lol-stage-1" on Cloudflare Pages.
# The site will be available at dana-lol-stage-1.pages.dev.
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

  # Direct Upload project — no `source` block. Every deploy goes
  # through `wrangler pages deploy` from GitHub Actions, so the
  # Cloudflare → GitHub App integration was unused dead weight, and
  # an unhealthy install threw 401 (CF error 8000011) on the matching
  # prod-1 apply. Match prod-1's shape for parity.

  # The dana-lol-staging project was originally created with a GitHub
  # source block (back when develop→master used CF Pages auto-deploys).
  # Cloudflare's API silently refuses to unset `source` on existing
  # projects: a direct PATCH with {"source": null} returns success but
  # the source persists on the next plan, and the dashboard's
  # "Disconnect" UI is hidden because the GitHub App install is in the
  # unhealthy state behind the original 8000011 error. The dead source
  # block stays attached but does nothing — every deploy goes through
  # wrangler from CI, not git push.
  lifecycle {
    ignore_changes = [source]
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

# Second custom domain: staging.dana.lol. Authoritative DNS for
# dana.lol lives in Route53 (not Cloudflare), so there's no
# cloudflare_dns_record partner here — the matching CNAME is in
# terraform/core/route53.tf:aws_route53_record.primary_staging.
# Cloudflare validates the TLS cert via that Route53-managed CNAME.
resource "cloudflare_pages_domain" "stage_1_staging_dana_lol" {
  account_id   = var.cloudflare_account_id
  project_name = cloudflare_pages_project.stage_1.name
  name         = "staging.dana.lol"
}
