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
  #
  # CLIPS is the round-set media, which the game reads at request time rather than
  # carrying: functions/clips/[[path]].js streams each clip out of the bucket, so a
  # round set no longer arrives by deploy. Without this binding every round is a
  # black pane — and because Pages answers a path it holds no file for with the
  # site's own HTML at status 200, a deployment missing it reads as healthy
  # everywhere except the screen. By name rather than by reference: the bucket is
  # declared in terraform/prod-1/cloudflare-r2-guessr-clips.tf, where the
  # cloudflare provider already lives, and state is split per environment so there
  # is nothing here to point at. One bucket for all three tiers is deliberate —
  # that file says why the media is shared where the answers are not.
  deployment_configs = {
    production = {
      d1_databases = { ANSWERS = { id = cloudflare_d1_database.guessr_answers_staging.id } }
      r2_buckets   = { CLIPS = { name = "adanalife-guessr-clips" } }
      env_vars = {
        DISCORD_WEBHOOK = {
          type  = "secret_text"
          value = data.aws_ssm_parameter.discord_alerts_webhook.value
        }
      }
    }
    preview = {
      d1_databases = { ANSWERS = { id = cloudflare_d1_database.guessr_answers_staging.id } }
      r2_buckets   = { CLIPS = { name = "adanalife-guessr-clips" } }
      env_vars = {
        DISCORD_WEBHOOK = {
          type  = "secret_text"
          value = data.aws_ssm_parameter.discord_alerts_webhook.value
        }
      }
    }
  }

  # deployment_configs is set on the project by hand; terraform can't write it.
  # Serializing an update, the cloudflare provider emits any binding value that
  # matches its sibling environment's as `{}` — which is every binding here,
  # since both environments carry the same three — Cloudflare answers `Invalid R2
  # bucket name ()`, and the whole PATCH fails, so nothing lands (5.19.1 through
  # 5.22.0, whose encoders are byte-identical). Deleting the block instead is
  # worse: an absent deployment_configs plans as unknown, which the provider
  # cannot convert at all.
  #
  # So the block above is a declaration of what this project is meant to carry,
  # and changing a binding means the dashboard — Workers & Pages →
  # adanalife-guessr-staging → Settings → Bindings, then a redeploy for it to
  # take effect. Both environments need each binding: main deploys to this
  # project's production environment and per-PR previews land on its branch
  # aliases. Drop this lifecycle block when the provider can write bindings again
  # and the next plan will show whatever drifted.
  lifecycle {
    ignore_changes = [deployment_configs]
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

  # The hint is create-time-only and the provider never reads it back into
  # state (observed on 5.22.0), so a declared value plans as an addition — and
  # an addition to a create-time attribute is a forced REPLACEMENT of a live
  # database. Ignored so the declaration keeps documenting what the database
  # was created with, without arming a destroy on every plan. See the
  # production copy: same trap, bigger blast radius.
  lifecycle {
    ignore_changes = [primary_location_hint]
  }
}

resource "cloudflare_pages_domain" "guessr_staging" {
  account_id   = var.cloudflare_account_id
  project_name = cloudflare_pages_project.guessr_staging.name
  name         = "stage.guessr.${var.primary_domain}"
}
