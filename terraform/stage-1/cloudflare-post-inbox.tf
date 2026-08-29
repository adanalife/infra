# The post-from-phone inbox for dana.lol (github.com/adanalife/website,
# worker/ and script/drain-inbox).
#
# Photos mailed to post@whalecore.com are handed by Email Routing to the
# `dana-lol-post-inbox` worker, which unpacks the attachments into this
# bucket; `task post:drain` on the laptop turns each message into a draft
# article PR. The worker itself is deployed by wrangler from the website
# repo (`task post:worker:deploy`), not by terraform — same split as the
# Pages projects — so the routing rule below names a script terraform does
# not manage: deploy the worker before applying, or the rule has nothing to
# point at.
#
# whalecore.com rather than dana.lol because Email Routing needs the zone's
# DNS on Cloudflare, and dana.lol's authority deliberately stays in Route53
# (see cloudflare-pages.tf in prod-1). Nothing is lost: the address is a
# private drop box, not a public contact point.

# wrangler 4 provisions a missing R2 binding on `wrangler deploy`, so the
# worker's first deploy creates this bucket before terraform gets to it.
# Adopt rather than recreate:
#   terraform import cloudflare_r2_bucket.post_inbox <account_id>/dana-lol-post-inbox/default
resource "cloudflare_r2_bucket" "post_inbox" {
  account_id = var.cloudflare_account_id
  name       = "dana-lol-post-inbox"
  location   = "WNAM"
}

# Enabling routing on the zone also writes the MX + SPF records it needs.
# (cloudflare_email_routing_dns is for routing on a *subdomain*; the API
# rejects it for the apex.)
resource "cloudflare_email_routing_settings" "stage_1" {
  zone_id = cloudflare_zone.stage_1.id
}

resource "cloudflare_email_routing_rule" "post_inbox" {
  zone_id = cloudflare_zone.stage_1.id
  name    = "post@ → dana-lol-post-inbox worker"
  enabled = true

  matchers = [{
    type  = "literal"
    field = "to"
    value = "post@${cloudflare_zone.stage_1.name}"
  }]

  actions = [{
    type  = "worker"
    value = ["dana-lol-post-inbox"]
  }]

  depends_on = [cloudflare_email_routing_settings.stage_1]
}
