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
# Two minutes rather than one, over three probes: Grafana Cloud bills a check
# per probe per execution, and this pace leaves room for a second check without
# revisiting the quota.
#
# Probe names are AWS-region-derived, not city-of-your-choosing — the data
# source keys on the exact name, and a wrong one fails the plan. The current
# list is `GET /api/v1/probe/list` on the SM API. Both coasts plus one
# transatlantic: a Cloudflare edge failure is regional, so a single-origin
# check reports green through one.
resource "grafana_synthetic_monitoring_check" "guessr" {
  job       = "guessr"
  target    = "https://guessr.dana.lol/api/leaderboard?board=daily"
  enabled   = true
  frequency = 120000
  timeout   = 10000
  probes = [
    data.grafana_synthetic_monitoring_probes.main.probes["NorthVirginia"],
    data.grafana_synthetic_monitoring_probes.main.probes["Oregon"],
    data.grafana_synthetic_monitoring_probes.main.probes["London"],
  ]
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
