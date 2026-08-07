# Production Cloudflare Pages project for guessr, the dashcam guessing
# game (github.com/adanalife/guessr), served at guessr.dana.lol. It moves
# only when a release tag ships; main deploys to the staging project in
# terraform/stage-1/cloudflare-pages-guessr.tf.
#
# The project name is "adanalife-guessr" rather than "guessr" because the
# pages.dev subdomain is a global namespace and guessr.pages.dev is taken.
#
# Lives in prod-1 alongside the blog's production project, the same split
# the blog uses. As with the blog, DNS authority for dana.lol stays in
# Route53 — the CNAME that both resolves the hostname and validates
# Cloudflare's TLS cert is in
# terraform/core/route53.tf:aws_route53_record.guessr.
resource "cloudflare_pages_project" "guessr" {
  account_id = var.cloudflare_account_id
  name       = "adanalife-guessr"

  production_branch = "main"

  # Direct Upload — deploys go through `wrangler pages deploy` from
  # GitHub Actions. Matches the blog's projects; see cloudflare-pages.tf
  # for why the git integration is avoided.

  # The answer coordinates, which is what makes the game's one endpoint
  # (functions/api/score.js) possible: the round manifest the browser
  # downloads carries no lat/lng, so a score can't be read out of devtools
  # or forged.
  #
  # The Discord webhook is for the coord-report button: a player who recognises
  # a street can say the round's coordinates are wrong, and a Pages Function is
  # what posts that somewhere it will be read. It has to arrive as a *Pages*
  # binding rather than a GitHub Actions secret, because the endpoint reads it at
  # request time, long after any workflow has finished — the release
  # notifications in guessr's release.yml read an Actions secret and the two are
  # not interchangeable.
  #
  # It reuses the existing alerts webhook rather than minting one. That parameter
  # already carries two consumers (Grafana's discord-alerts contact point and
  # tripbot's !report command), and a player reporting bad coordinates is the
  # same kind of thing as a !report — both are somebody telling us something is
  # wrong, in a channel that is read rather than watched.
  #
  # CLIPS is the round-set media, which the game reads at request time rather than
  # carrying: functions/clips/[[path]].js streams each clip out of the bucket, so a
  # round set no longer arrives by deploy. Without this binding every round is a
  # black pane — and because Pages answers a path it holds no file for with the
  # site's own HTML at status 200, a deployment missing it reads as healthy
  # everywhere except the screen. Referenced rather than named here, unlike the
  # staging copy, because cloudflare-r2-guessr-clips.tf is in this same state.
  #
  # Production is the only environment declared, so a preview deploy of *this*
  # project gets no bindings and would fail every guess. Nothing deploys one —
  # per-PR previews land on the staging project
  # (terraform/stage-1/cloudflare-pages-guessr.tf) and a tag deploys this one to
  # its production environment — and a second environment cannot be declared
  # anyway: the cloudflare provider serializes two deployment_configs
  # environments holding identical binding values by emitting the second as `{}`,
  # which Cloudflare rejects with `Invalid R2 bucket name ()`. That fails the
  # whole PATCH, so the bindings below don't land either. Still true in 5.22.0,
  # so a provider bump doesn't lift this.
  deployment_configs = {
    production = {
      d1_databases = { ANSWERS = { id = cloudflare_d1_database.guessr_answers.id } }
      r2_buckets   = { CLIPS = { name = cloudflare_r2_bucket.guessr_clips.name } }
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
  # matches its sibling environment's as `{}`, Cloudflare answers `Invalid R2
  # bucket name ()`, and the whole PATCH fails — so nothing lands, env vars
  # included (5.19.1 through 5.22.0, whose encoders are byte-identical). Deleting
  # the block instead is worse: an absent deployment_configs plans as unknown,
  # which the provider cannot convert at all.
  #
  # So the block above is a declaration of what this project is meant to carry,
  # and changing a binding means the dashboard — Workers & Pages →
  # adanalife-guessr → Settings → Bindings, then a redeploy for it to take
  # effect. Drop this lifecycle block when the provider can write bindings again
  # and the next plan will show whatever drifted.
  lifecycle {
    ignore_changes = [deployment_configs]
  }
}

# Seeded out-of-band, by `task answers:prod:push` from the guessr repo — the
# coords come from the dashcam corpus, which only Dana's laptop can reach, so
# there is nothing for CI or terraform to populate this from. Empty until that
# push runs, and a deploy against an empty table serves "unknown round" for
# every guess.
#
# Free tier covers this comfortably: ~300 rows, one indexed read per guess,
# against 5 GB of storage and 5M row-reads a day.
resource "cloudflare_d1_database" "guessr_answers" {
  account_id = var.cloudflare_account_id
  name       = "adanalife-guessr-answers"

  # Same continent as the corpus and the players; D1 has no multi-region
  # story worth buying at this size.
  primary_location_hint = "wnam"

  # Declared rather than left to default, and load-bearing: the API returns this
  # object on every read, so an absent block reads as "set it to null" and every
  # subsequent plan carries an update that the API then rejects with
  # `Invalid property: read_replication => Expected object, received null`.
  # Any change to this file inherits that failure until the block is here.
  read_replication = {
    mode = "disabled"
  }

  # The hint is create-time-only and the provider never reads it back into
  # state (observed on 5.22.0), so a declared value plans as an addition — and
  # an addition to a create-time attribute is a forced REPLACEMENT of this
  # database, which holds `plays`: the one table nothing can regenerate.
  # Ignored so the declaration keeps documenting what the database was created
  # with, without arming a destroy the moment prod-1's provider catches up to
  # stage-1's (where the plan-time replacement was first observed).
  lifecycle {
    ignore_changes = [primary_location_hint]
  }
}

resource "cloudflare_pages_domain" "guessr" {
  account_id   = var.cloudflare_account_id
  project_name = cloudflare_pages_project.guessr.name
  name         = "guessr.${var.primary_domain}"
}

# The misspellings, so a near miss serves the game instead of a certificate
# error. Keep the list in sync with aws_route53_record.guessr_aliases in
# terraform/core/route53.tf, which carries the reasoning and the CNAMEs — a
# Pages domain with no DNS record never validates, and a CNAME with no Pages
# domain reaches a project that refuses to answer for the hostname.
#
# The aliases *serve* the game rather than redirecting to guessr.dana.lol.
# Cloudflare's redirect rules need the zone to live in Cloudflare and dana.lol's
# authority is Route53, so a 301 would mean a Pages Function in front of every
# request — for a canonical URL the game already has: the share string is a
# hardcoded https://guessr.dana.lol, whatever host it was played on, and the
# page carries a rel=canonical for crawlers.
resource "cloudflare_pages_domain" "guessr_aliases" {
  for_each = toset([
    # the correct English word, and the word people remember
    "guesser", "guess", "guessers",
    # a dropped, doubled or tripled letter
    "guesr", "gessr", "guessrr", "guesssr",
    # adjacent letters swapped -- "geuss" is the classic one
    "geussr", "gusesr",
    # the other agent-noun ending, and a plural of the brand
    "guessor", "guessrs",
  ])

  account_id   = var.cloudflare_account_id
  project_name = cloudflare_pages_project.guessr.name
  name         = "${each.key}.${var.primary_domain}"
}

# ---------------------------------------------------------------------------
# The login in front of guessr's admin surface on the production game.
#
# /admin/ serves a scheduled day with its answer coordinates joined on, and can
# throw a round out of a day nobody has played yet. Staging has had this since
# the surface was closed (terraform/stage-1/cloudflare-pages-guessr.tf, which
# carries the reasoning this one does not repeat: why the application fronts
# pages.dev rather than the custom domain, why the emails come from SSM, and the
# post-apply steps below). That application's destinations are the staging
# project's hostnames, so it does nothing for this project.
#
# What makes production worth reviewing at all is that its schedule is the one a
# wrong coordinate reaches players through. A day checked on staging is a day
# checked in the wrong database.
#
# No wildcard destination, unlike staging. Per-PR previews land on the staging
# project and nothing deploys a preview of this one; a branch alias made by hand
# would carry none of the variables below and so answers 503, which is the safe
# direction and the reason this does not need to enumerate hostnames nobody
# creates.
#
# AFTER AN APPLY, two values have to reach the Pages project by hand — terraform
# cannot write them, per the deployment_configs lifecycle block above:
#
#   terraform output guessr_prod_admin_access_aud
#
# then Workers & Pages → adanalife-guessr → Settings → Variables, ACCESS_AUD to
# that value and ACCESS_TEAM_DOMAIN to the team domain
# (<team>.cloudflareaccess.com). Production is the only environment this project
# declares, so it is the only one to set them on. Then redeploy, because a Pages
# variable only reaches a build that starts after it. Until that is done /admin/
# answers 503 here and serves nothing.
locals {
  guessr_admin_emails = jsondecode(data.aws_ssm_parameter.guessr_admin_emails.value)
}

resource "cloudflare_zero_trust_access_application" "guessr_admin" {
  account_id           = var.cloudflare_account_id
  name                 = "guessr admin (production)"
  type                 = "self_hosted"
  session_duration     = "24h"
  app_launcher_visible = false

  destinations = [
    {
      type = "public"
      uri  = "${cloudflare_pages_project.guessr.name}.pages.dev/admin"
    },
  ]

  policies = [
    {
      id         = cloudflare_zero_trust_access_policy.guessr_admin.id
      precedence = 1
    },
  ]
}

# Allow, not bypass: the point is to know who is looking. With no identity
# provider configured Access falls back to a one-time PIN mailed to the address,
# which is the whole setup for a one-person tool.
#
# Its own policy rather than the staging one reused, because that resource is in
# another state and another AWS account's parameter feeds it. Two allowlists is
# the honest shape anyway: this one governs the schedule players are getting.
resource "cloudflare_zero_trust_access_policy" "guessr_admin" {
  account_id = var.cloudflare_account_id
  name       = "guessr — allow the admin emails (production)"
  decision   = "allow"

  include = [
    for email in local.guessr_admin_emails : {
      email = {
        email = email
      }
    }
  ]

  # An Access policy with no include rules is not a policy, and the API's own
  # error for it says nothing about where the list comes from -- hence this
  # precondition, which names the parameter instead.
  #
  # It takes two applies, and the order is the part worth writing down. The
  # parameter is terraform's (secrets.tf), so seeding it by hand first is what
  # NOT to do: `put-parameter` creates it outside state and the next apply dies
  # on `ParameterAlreadyExists` before reaching anything here. Let terraform
  # create it empty, which fails on this precondition, then fill it and go again:
  #
  #   task tf:prod:apply    # creates the parameter, stops here
  #   aws-vault exec adanalife-prod -- aws ssm put-parameter \
  #     --name /prod-1/guessr-admin-emails --type SecureString --overwrite \
  #     --value '["you@example.com"]'
  #   task tf:prod:apply    # the policy, the application, the AUD output
  #
  # Already seeded it by hand? `terraform import
  # aws_ssm_parameter.guessr_admin_emails /prod-1/guessr-admin-emails` adopts it
  # in one step, and `ignore_changes = [value]` means the addresses survive.
  lifecycle {
    precondition {
      condition     = length(local.guessr_admin_emails) > 0
      error_message = "Seed /prod-1/guessr-admin-emails with a JSON array of email addresses, then apply again — see the runbook above this precondition."
    }
  }
}

# Set ACCESS_AUD on the Pages project to this. The AUD is an application
# identifier rather than a credential — it is a claim inside every token Access
# hands a browser — but it is what guessr's middleware pins, so that a token
# minted for the staging application is not a token for this one.
output "guessr_prod_admin_access_aud" {
  value       = cloudflare_zero_trust_access_application.guessr_admin.aud
  description = "AUD tag of the production guessr admin Access application. Set as ACCESS_AUD on the Pages project."
}

# Web Analytics for the game — who visits, as opposed to how they play, which
# is already in the D1 `plays` table and read back by `task stats:prod` in the
# guessr repo. Enabled on the Pages project itself (Workers & Pages →
# adanalife-guessr → Metrics → Web Analytics), not here, and deliberately:
#
# A `cloudflare_web_analytics_site` resource is what belongs in this file, but
# creating one is a POST to /rum/site_info, and Cloudflare publishes no
# account-scoped token permission that grants it — only `Account Analytics
# Read`. The terraform token in /prod-1/cloudflare-api-token gets a bare 403,
# and no permission can be added to fix it. The Pages toggle needs no token: it
# injects the beacon into the HTML the project already serves, which covers the
# custom domain and the misspelling aliases along with it.
#
# So this is click-ops on purpose. If a write permission ever appears, the
# resource is four lines and this comment is the reason it wasn't here.
