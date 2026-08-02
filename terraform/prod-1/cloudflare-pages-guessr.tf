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

  # Declared rather than left to default, and load-bearing: the API returns this
  # object on every read, so an absent block reads as "set it to null" and every
  # subsequent plan carries an update that the API then rejects with
  # `Invalid property: read_replication => Expected object, received null`.
  # Any change to this file inherits that failure until the block is here.
  read_replication = {
    mode = "disabled"
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

# Cloudflare Web Analytics for the game: the "did anyone visit" half of knowing
# how it is doing. The other half — how they played, where they dropped off,
# which frames are brutal — is already in the D1 `plays` table and is read back
# by `task stats:prod` in the guessr repo. This counts the people who never
# guessed, whom that table cannot see.
#
# Cookieless and IP-less, which is why it and not Google: the game's privacy
# story is a localStorage disclosure (a player id and a typed handle) and an
# analytics tool that sets a cookie or stores an address would change that.
#
# auto_install is off because it only works for orange-clouded sites, and
# dana.lol's DNS authority is Route53 — the zone is not in Cloudflare at all,
# so there is no edge injection to turn on. The beacon goes in web/index.html
# by hand instead, keyed on the site_tag below.
resource "cloudflare_web_analytics_site" "guessr" {
  account_id   = var.cloudflare_account_id
  host         = cloudflare_pages_domain.guessr.name
  auto_install = false
}

# The token the beacon in guessr's web/index.html carries. Not a secret — it is
# served to every visitor in the page source, and it identifies which site a
# hit belongs to rather than authorising anything. Output because the beacon is
# hand-placed: apply this, then paste the value into the game.
output "guessr_web_analytics_token" {
  description = "Cloudflare Web Analytics site tag for the beacon in guessr's web/index.html"
  value       = cloudflare_web_analytics_site.guessr.site_tag
}
