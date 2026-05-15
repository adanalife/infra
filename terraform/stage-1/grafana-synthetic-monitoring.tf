# Grafana Cloud Synthetic Monitoring — HTTP checks for public endpoints.
#
# Requires two additional fields in the stage-1/grafana-cloud-api SM blob
# (alongside the existing GRAFANA_CLOUD_URL / GRAFANA_CLOUD_API_TOKEN / STACK_SLUG):
#
#   "GRAFANA_SM_URL":          "https://synthetic-monitoring-api.grafana.net"
#   "GRAFANA_SM_ACCESS_TOKEN": "<GC access policy token with synthetic-monitoring:read+write scopes>"
#
# Mint the SM access policy at https://grafana.com/orgs/<slug>/access-policies.
# Then extend the SM blob:
#
#   aws-vault exec adanalife-stage -- aws secretsmanager put-secret-value \
#     --secret-id stage-1/grafana-cloud-api \
#     --secret-string '{
#       "GRAFANA_CLOUD_URL":          "https://<slug>.grafana.net",
#       "GRAFANA_CLOUD_API_TOKEN":    "glsa_...",
#       "GRAFANA_CLOUD_STACK_SLUG":   "<slug>",
#       "GRAFANA_SM_URL":             "https://synthetic-monitoring-api.grafana.net",
#       "GRAFANA_SM_ACCESS_TOKEN":    "glc_..."
#     }'
#
# After seeding, run `task tf:stage:apply` to activate the checks.
# Checks appear under Grafana Cloud → Testing & Synthetics → Checks.

data "grafana_synthetic_monitoring_probes" "main" {}

locals {
  sm_probes = [
    data.grafana_synthetic_monitoring_probes.main.probes["Atlanta"],
    data.grafana_synthetic_monitoring_probes.main.probes["Frankfurt"],
    data.grafana_synthetic_monitoring_probes.main.probes["Tokyo"],
  ]
}

resource "grafana_synthetic_monitoring_check" "tripbot" {
  job       = "tripbot-http"
  target    = "https://tripbot.whalecore.com"
  enabled   = true
  frequency = 60000
  timeout   = 5000
  probes    = local.sm_probes

  settings {
    http {
      valid_status_codes  = [200]
      no_follow_redirects = false
    }
  }
}

resource "grafana_synthetic_monitoring_check" "vlc_server" {
  job       = "vlc-http"
  target    = "https://vlc.whalecore.com"
  enabled   = true
  frequency = 60000
  timeout   = 5000
  probes    = local.sm_probes

  settings {
    http {
      valid_status_codes  = [200]
      no_follow_redirects = false
    }
  }
}

resource "grafana_synthetic_monitoring_check" "dana_lol" {
  job       = "dana-lol-http"
  target    = "https://dana.lol"
  enabled   = true
  frequency = 60000
  timeout   = 5000
  probes    = local.sm_probes

  settings {
    http {
      valid_status_codes  = [200]
      no_follow_redirects = false
    }
  }
}

resource "grafana_synthetic_monitoring_check" "www_whalecore" {
  job       = "www-whalecore-http"
  target    = "https://www.whalecore.com"
  enabled   = true
  frequency = 60000
  timeout   = 5000
  probes    = local.sm_probes

  settings {
    http {
      valid_status_codes  = [200]
      no_follow_redirects = false
    }
  }
}
