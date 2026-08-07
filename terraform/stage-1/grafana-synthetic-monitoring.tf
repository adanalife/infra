# Synthetic Monitoring: black-box probes of the public endpoints, from
# outside the cluster. The counterpart to the in-cluster alerting in
# grafana-alerts.tf, which cannot tell you that the thing is unreachable.
#
# This replaces the UptimeRobot account behind status.dana.lol as the place
# checks are defined. That account is 2020-era and two of its three monitors
# are paused, so the page it serves reports green through an outage.

# Synthetic Monitoring. The tenant is already installed on the stack, so this
# reads an access token created from its own settings page rather than running
# `grafana_synthetic_monitoring_installation`, which would try to install it a
# second time.
data "grafana_synthetic_monitoring_probes" "main" {}

# Probe names are AWS-region-derived, not city-of-your-choosing — the data
# source keys on the exact name, and a wrong one fails the plan. The current
# list is `GET /api/v1/probe/list` on the SM API. Both coasts plus one
# transatlantic: a Cloudflare edge failure is regional, so a single-origin
# check reports green through one.
locals {
  sm_probes = [
    data.grafana_synthetic_monitoring_probes.main.probes["NorthVirginia"],
    data.grafana_synthetic_monitoring_probes.main.probes["Oregon"],
    data.grafana_synthetic_monitoring_probes.main.probes["London"],
  ]
}

# Quota. The free tier covers 100k API test executions/month and bills per
# probe per execution, so three probes cost 21.9k/month at a 120s pace and
# 13.1k at 600s. The checks below come to ~92k. A fourth check wants a slower
# pace on all of them rather than another 13k on top; past 100k it is $5/10k.

# The target is the leaderboard endpoint and not the page, because it is the
# one request that exercises both halves at once: Pages serving the deploy, and
# the D1 binding answering behind it. A page-only check stays green through a
# database the game cannot read.
#
# `fail_if_body_not_matches_regexp` is the load-bearing line, not belt and
# braces. Pages answers a path with no file with **200 and the site's own
# HTML**, so a check asserting only on the status code passes against a
# deployment that is missing the whole API -- which is not hypothetical:
# production answers /api/day exactly that way today, having never had it.
#
# Two minutes rather than one: the game is the endpoint a visitor is most
# likely to be sitting in front of, so it gets the fastest pace the quota above
# will carry.
resource "grafana_synthetic_monitoring_check" "guessr" {
  job       = "guessr"
  target    = "https://guessr.dana.lol/api/leaderboard?board=daily"
  enabled   = true
  frequency = 120000
  timeout   = 10000
  probes    = local.sm_probes
  labels = {
    tier = "production"
  }

  settings {
    http {
      method                          = "GET"
      ip_version                      = "V4"
      valid_status_codes              = [200]
      fail_if_body_not_matches_regexp = ["\"board\""]
    }
  }
}

# The apex rather than www.dana.lol, so the redirect to the canonical host is
# inside what the check covers — it is terraform-managed in core/ and is its
# own way for the site to become unreachable while the origin is healthy.
#
# The body assertion earns its place the same way it does on guessr: this is a
# Pages deployment, so a build that publishes nothing still answers 200 with
# something. Matching the site's title is what distinguishes the site from a
# 200 that merely proves Cloudflare is up.
resource "grafana_synthetic_monitoring_check" "dana_lol" {
  job       = "dana-lol"
  target    = "https://dana.lol"
  enabled   = true
  frequency = 600000
  timeout   = 10000
  probes    = local.sm_probes
  labels = {
    tier = "production"
  }

  settings {
    http {
      method                          = "GET"
      ip_version                      = "V4"
      valid_status_codes              = [200]
      fail_if_body_not_matches_regexp = ["A Dana Life"]
    }
  }
}

# Serves the same site as dana.lol but from a separate origin behind separate
# DNS and a separate certificate, so it fails independently and needs its own
# check rather than riding on the one above. www rather than the apex: the
# apex does not resolve.
resource "grafana_synthetic_monitoring_check" "whalecore" {
  job       = "whalecore"
  target    = "https://www.whalecore.com"
  enabled   = true
  frequency = 600000
  timeout   = 10000
  probes    = local.sm_probes
  labels = {
    tier = "production"
  }

  settings {
    http {
      method                          = "GET"
      ip_version                      = "V4"
      valid_status_codes              = [200]
      fail_if_body_not_matches_regexp = ["A Dana Life"]
    }
  }
}
