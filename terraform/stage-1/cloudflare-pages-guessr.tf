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

# ---------------------------------------------------------------------------
# The login in front of guessr's admin surface.
#
# /admin/ serves the schedule nobody has played yet with its answer coordinates
# joined on, and since guessr#100 it can also throw a round out of an upcoming
# day. On staging and on every per-PR preview that was reachable by anyone who
# knew the URL, and a promotion copies staging's schedule to production — so from
# the cutover on, the open surface named production's future five.
#
# WHY pages.dev AND NOT stage.guessr.dana.lol: a self-hosted Access application
# wants its hostname on a Cloudflare zone, and dana.lol's authoritative DNS is
# Route53 (terraform/core/route53.tf). The pages.dev name is Cloudflare's own, so
# it is coverable today without moving the zone. The custom domain is protected
# the other way round — it never carries an Access JWT, and guessr's
# functions/admin/_middleware.js refuses every admin request that arrives
# without one. So the review surface lives here and nowhere else.
#
# Scoped to the /admin path. The game itself is the public half of this project
# and an application over the bare hostname would put a login in front of it.
#
# The AUD this creates has to reach the Pages project as an environment
# variable, and terraform cannot write those (see the deployment_configs
# lifecycle block above). After an apply:
#
#   terraform output guessr_admin_access_aud
#
# then Workers & Pages → adanalife-guessr-staging → Settings → Variables, and
# set ACCESS_AUD to that value and ACCESS_TEAM_DOMAIN to the team domain (Zero
# Trust → Settings → Custom Pages shows it, as <team>.cloudflareaccess.com) on
# BOTH the production and preview environments — main deploys to this project's
# production environment and per-PR previews land on its branch aliases. Then
# redeploy, because a Pages variable only reaches a build that starts after it.
# Until that is done the admin surface answers 503 and serves nothing, which is
# the safe direction and is what every tier looks like today.
locals {
  guessr_admin_emails = jsondecode(data.aws_ssm_parameter.guessr_admin_emails.value)
}

resource "cloudflare_zero_trust_access_application" "guessr_staging_admin" {
  account_id           = var.cloudflare_account_id
  name                 = "guessr admin (staging)"
  type                 = "self_hosted"
  session_duration     = "24h"
  app_launcher_visible = false

  destinations = [
    # The project's own pages.dev hostname, and the branch aliases every PR
    # preview lands on — those hold the same round set and the same answers, so
    # gating one and not the other would be gating nothing.
    {
      type = "public"
      uri  = "${cloudflare_pages_project.guessr_staging.name}.pages.dev/admin"
    },
    {
      type = "public"
      uri  = "*.${cloudflare_pages_project.guessr_staging.name}.pages.dev/admin"
    },
  ]

  policies = [
    {
      id         = cloudflare_zero_trust_access_policy.guessr_admin.id
      precedence = 1
    },
  ]
}

# Allow, not bypass: the point is to know who is looking, so an identity has to
# be proved. With no identity provider configured Access falls back to a
# one-time PIN mailed to the address — which is the whole setup for a one-person
# tool, and needs no OAuth application registered anywhere.
#
# Emails come from SSM rather than this file because this repo is public.
resource "cloudflare_zero_trust_access_policy" "guessr_admin" {
  account_id = var.cloudflare_account_id
  name       = "guessr — allow the admin emails"
  decision   = "allow"

  include = [
    for email in local.guessr_admin_emails : {
      email = {
        email = email
      }
    }
  ]

  # An Access policy with no include rules is not a policy, and the API's own
  # error for it says nothing about where the list comes from. Seed the
  # parameter first:
  #
  #   aws-vault exec adanalife-stage -- aws ssm put-parameter \
  #     --name /stage-1/guessr-admin-emails --type SecureString --overwrite \
  #     --value '["you@example.com"]'
  lifecycle {
    precondition {
      condition     = length(local.guessr_admin_emails) > 0
      error_message = "Seed /stage-1/guessr-admin-emails with a JSON array of email addresses before applying."
    }
  }
}

# Set ACCESS_AUD on the Pages project to this. The AUD is an application
# identifier rather than a credential — it is a claim inside every token Access
# hands a browser — but it is what guessr's middleware pins so that a token
# minted for another application in this account is not a token for this one.
output "guessr_admin_access_aud" {
  value       = cloudflare_zero_trust_access_application.guessr_staging_admin.aud
  description = "AUD tag of the guessr admin Access application. Set as ACCESS_AUD on the Pages project."
}
