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
# probe per execution, so one probe costs 14.6k/month at a 180s pace, 8.8k at
# 300s and 4.4k at 600s. The checks below come to ~92k. Another check wants a
# slower pace on all of them rather than more on top; past 100k it is $5/10k.

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
# Three minutes: the game is the endpoint a visitor is most likely to be
# sitting in front of, so it gets the fastest pace the quota above will carry
# alongside the channel-live checks.
resource "grafana_synthetic_monitoring_check" "guessr" {
  job       = "guessr"
  target    = "https://guessr.dana.lol/api/leaderboard?board=daily"
  enabled   = true
  frequency = 180000
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

# The other half of guessr that can break without the game noticing: the login
# on /admin. The game gates that surface on a Twitch bearer token and answers
# 401 to a request that carries none -- closed to a stranger, open to Dana once
# he signs in. 401 is therefore the healthy answer, not 200: a 2xx is the admin
# surface answering a stranger, and anything else is the gate having moved (a
# 302 is Cloudflare Access back in front of it; a 5xx is the Worker down). The
# body assertion pins the refusal to *the game's* gate rather than any other
# 401 on the path.
#
# guessr's smoke.sh asserts the same on every deploy, which is the gap this
# fills -- a gate that rots between releases stays invisible until the next
# tag.
#
# One probe, not local.sm_probes: the gate is the same from every region, so
# the regional diversity the other checks need buys nothing here. Ten minutes,
# not two, for the same reason. Together they cost ~4.4k executions/month,
# included in the quota note's total above.
resource "grafana_synthetic_monitoring_check" "guessr_admin" {
  job       = "guessr-admin"
  target    = "https://guessr.dana.lol/admin/"
  enabled   = true
  frequency = 600000
  timeout   = 10000
  probes    = [data.grafana_synthetic_monitoring_probes.main.probes["NorthVirginia"]]
  labels = {
    tier = "production"
  }

  settings {
    http {
      method                          = "GET"
      ip_version                      = "V4"
      valid_status_codes              = [401]
      fail_if_body_not_matches_regexp = ["sign in with Twitch"]
    }
  }
}

# Is the channel live, asked the way a viewer would. The in-cluster stream
# rules read series the minipc pushes, so a minipc that cannot reach Grafana
# Cloud reads as no data, and no data is OK on those rules -- both streams were
# dark for 74 minutes on 2026-10-15 without `OBS: stream is down` firing. These
# two depend on nothing in the house. The rule that pages on them is
# "Every platform is off-air" in grafana-alerts.tf.
#
# Neither needs a credential. Twitch serves a channel's preview thumbnail with
# 200 while it is live and 302s to a placeholder image while it is not, so the
# check refuses redirects and wants the 200. YouTube's /live path renders the
# live video while there is one, with a canonical link to its watch page, and
# the channel page otherwise.
#
# One probe each, in the US: the answer is the same from every region, and
# YouTube can put a consent page in front of a European probe. Five minutes,
# which the off-air rule's window is sized against.
resource "grafana_synthetic_monitoring_check" "twitch_live" {
  job       = "twitch-live"
  target    = "https://static-cdn.jtvnw.net/previews-ttv/live_user_adanalife_-80x45.jpg"
  enabled   = true
  frequency = 300000
  timeout   = 10000
  probes    = [data.grafana_synthetic_monitoring_probes.main.probes["NorthVirginia"]]
  labels = {
    tier = "production"
  }

  settings {
    http {
      method              = "GET"
      ip_version          = "V4"
      no_follow_redirects = true
      valid_status_codes  = [200]
    }
  }
}

resource "grafana_synthetic_monitoring_check" "youtube_live" {
  job       = "youtube-live"
  target    = "https://www.youtube.com/channel/UC8Q7uFC1Xyr2ZnTWOk9Aizg/live"
  enabled   = true
  frequency = 300000
  timeout   = 10000
  probes    = [data.grafana_synthetic_monitoring_probes.main.probes["NorthVirginia"]]
  labels = {
    tier = "production"
  }

  settings {
    http {
      method                          = "GET"
      ip_version                      = "V4"
      valid_status_codes              = [200]
      fail_if_body_not_matches_regexp = ["<link rel=\"canonical\" href=\"https://www\\.youtube\\.com/watch\\?v="]
    }
  }
}
