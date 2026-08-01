# Cloudflare Pages projects for guessr, the dashcam guessing game
# (github.com/adanalife/guessr).
#
# The stage/prod pair the blog uses, for the same reason: the repo is
# Direct Upload, which gets no per-branch preview deploys, so without a
# staging project every merge to main lands on the URL people play. Main
# deploys to staging; guessr.dana.lol only moves when a release tag ships.
#
# The project names carry an "adanalife-" prefix because the pages.dev
# subdomain is a global namespace and guessr.pages.dev is taken.
#
# Both live in prod-1 because that's where the cloudflare provider and the
# API token are (cloudflare-pages.tf, secrets.tf) — staging here is a
# deploy tier, not an AWS account. As with the blog, DNS authority for
# dana.lol stays in Route53; the CNAMEs that both resolve the hostnames
# and validate Cloudflare's TLS certs are in terraform/core/route53.tf.
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

# Staging: whatever is on main. Same shape as the production project, and
# deliberately the same content — the point is to play the next release
# before it is the release.
resource "cloudflare_pages_project" "guessr_staging" {
  account_id = var.cloudflare_account_id
  name       = "adanalife-guessr-staging"

  # The Pages project's own production branch, which is what
  # `wrangler pages deploy --branch main` targets. Unrelated to the git
  # branch being deployed; both tiers deploy from main.
  production_branch = "main"
}

resource "cloudflare_pages_domain" "guessr_staging" {
  account_id   = var.cloudflare_account_id
  project_name = cloudflare_pages_project.guessr_staging.name
  name         = "stage.guessr.${var.primary_domain}"
}
