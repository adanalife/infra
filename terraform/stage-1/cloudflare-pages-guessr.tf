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

  # The answer coordinates for this tier, which the game's one endpoint
  # (functions/api/score.js) scores guesses against — the round manifest the
  # browser downloads carries no lat/lng. Its own database rather than
  # prod's: the round sets diverge the moment one is regenerated and the
  # other isn't, and terraform state is split per environment anyway.
  #
  # Both configs, because this project serves both. Every merge to main is a
  # production deploy here, and per-PR previews land on branch aliases of
  # this same project.
  #
  # The Discord webhook backs the coord-report button, as a Pages binding because
  # the endpoint reads it per request. Staging gets it so the button can be
  # exercised end to end before a tag ships it — the production copy in
  # terraform/prod-1/cloudflare-pages-guessr.tf carries the rest of the
  # reasoning, including why this reuses the alerts webhook instead of minting
  # one.
  #
  # Both tiers post to the same channel, so the endpoint has to say which tier a
  # report came from or a staging test is indistinguishable from a real report.
  deployment_configs = {
    production = {
      d1_databases = { ANSWERS = { id = cloudflare_d1_database.guessr_answers_staging.id } }
      env_vars = {
        DISCORD_WEBHOOK = {
          type  = "secret_text"
          value = data.aws_ssm_parameter.discord_alerts_webhook.value
        }
      }
    }
    preview = {
      d1_databases = { ANSWERS = { id = cloudflare_d1_database.guessr_answers_staging.id } }
      env_vars = {
        DISCORD_WEBHOOK = {
          type  = "secret_text"
          value = data.aws_ssm_parameter.discord_alerts_webhook.value
        }
      }
    }
  }
}

# Seeded by `task answers:stage:push` from the guessr repo. See the production
# copy in terraform/prod-1/cloudflare-pages-guessr.tf for why nothing
# automated can populate it.
resource "cloudflare_d1_database" "guessr_answers_staging" {
  account_id = var.cloudflare_account_id
  name       = "adanalife-guessr-answers-staging"

  primary_location_hint = "wnam"

  # Required, not cosmetic — see the production copy for what omitting it does
  # to every plan that touches this file.
  read_replication = {
    mode = "disabled"
  }
}

resource "cloudflare_pages_domain" "guessr_staging" {
  account_id   = var.cloudflare_account_id
  project_name = cloudflare_pages_project.guessr_staging.name
  name         = "stage.guessr.${var.primary_domain}"
}
