# Cloudflare Pages project for guessr, the dashcam guessing game
# (github.com/adanalife/guessr), served at guessr.dana.lol.
#
# One project, not the stage/prod pair the blog uses: guessr is a static
# site with no backend to stage against, and Pages already gives every
# non-production branch a free preview deploy at <hash>.<project>.pages.dev.
# A second project would only add a name to keep in sync.
#
# The project name is "adanalife-guessr" rather than "guessr" because the
# pages.dev subdomain is a global namespace and guessr.pages.dev is taken.
#
# Lives in prod-1 because that's where the cloudflare provider and the
# API token are (cloudflare-pages.tf, secrets.tf). As with the blog, DNS
# authority for dana.lol stays in Route53 — the CNAME that both resolves
# the hostname and validates Cloudflare's TLS cert is in
# terraform/core/route53.tf:aws_route53_record.guessr.
resource "cloudflare_pages_project" "guessr" {
  account_id = var.cloudflare_account_id
  name       = "adanalife-guessr"

  production_branch = "main"

  # Direct Upload — deploys go through `wrangler pages deploy` from
  # GitHub Actions. Matches the blog's projects; see cloudflare-pages.tf
  # for why the git integration is avoided.
}

resource "cloudflare_pages_domain" "guessr" {
  account_id   = var.cloudflare_account_id
  project_name = cloudflare_pages_project.guessr.name
  name         = "guessr.${var.primary_domain}"
}
