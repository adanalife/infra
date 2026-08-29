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

resource "cloudflare_r2_bucket" "post_inbox" {
  account_id = var.cloudflare_account_id
  name       = "dana-lol-post-inbox"
  location   = "WNAM"
}

# Adds the MX + SPF records Email Routing needs on the zone.
resource "cloudflare_email_routing_dns" "stage_1" {
  zone_id = cloudflare_zone.stage_1.id
  name    = cloudflare_zone.stage_1.name
}

resource "cloudflare_email_routing_settings" "stage_1" {
  zone_id    = cloudflare_zone.stage_1.id
  depends_on = [cloudflare_email_routing_dns.stage_1]
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
