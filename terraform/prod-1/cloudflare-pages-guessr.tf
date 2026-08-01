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
  # or forged. Preview gets the same database — the previews that matter
  # land in the staging project, but a preview deploy here with no binding
  # would fail every guess rather than say why.
  deployment_configs = {
    production = {
      d1_databases = { ANSWERS = { id = cloudflare_d1_database.guessr_answers.id } }
    }
    preview = {
      d1_databases = { ANSWERS = { id = cloudflare_d1_database.guessr_answers.id } }
    }
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
}

resource "cloudflare_pages_domain" "guessr" {
  account_id   = var.cloudflare_account_id
  project_name = cloudflare_pages_project.guessr.name
  name         = "guessr.${var.primary_domain}"
}
