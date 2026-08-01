# Staging Cloudflare Pages project for guessr, the dashcam guessing game
# (github.com/adanalife/guessr), served at stage.guessr.dana.lol.
#
# Every merge to main lands here; guessr.dana.lol only moves when a release
# tag ships. The repo is Direct Upload, which gets no per-branch preview
# deploys, so without this project every merge went straight to the URL
# people play.
#
# Same stage-1/prod-1 split as the blog: the production project is in
# terraform/prod-1/cloudflare-pages-guessr.tf, and the cloudflare provider
# and API token this needs are already here for dana-lol-staging
# (cloudflare-pages.tf, secrets.tf). DNS authority for dana.lol stays in
# Route53 — the CNAME that both resolves the hostname and validates
# Cloudflare's TLS cert is in
# terraform/core/route53.tf:aws_route53_record.guessr_staging.
#
# The name carries an "adanalife-" prefix because the pages.dev subdomain
# is a global namespace and guessr.pages.dev is taken.
resource "cloudflare_pages_project" "guessr_staging" {
  account_id = var.cloudflare_account_id
  name       = "adanalife-guessr-staging"

  # The Pages project's own production branch, which is what
  # `wrangler pages deploy --branch main` targets. Unrelated to the git
  # branch being deployed; both tiers deploy from main.
  production_branch = "main"

  # Direct Upload — deploys go through `wrangler pages deploy` from GitHub
  # Actions. Unlike dana-lol-staging next door, this project was created
  # that way from the start, so it needs no `ignore_changes = [source]` to
  # tolerate a dead git source block.
}

resource "cloudflare_pages_domain" "guessr_staging" {
  account_id   = var.cloudflare_account_id
  project_name = cloudflare_pages_project.guessr_staging.name
  name         = "stage.guessr.${var.primary_domain}"
}
