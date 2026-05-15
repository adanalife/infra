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

locals {
  sm_enabled = lookup(local.grafana_creds, "GRAFANA_SM_ACCESS_TOKEN", "placeholder") != "placeholder"
}

# Skipped until GRAFANA_SM_ACCESS_TOKEN is seeded in the SM blob.
data "grafana_synthetic_monitoring_probes" "main" {
  count = local.sm_enabled ? 1 : 0
}

locals {
  sm_probes = local.sm_enabled ? [
    data.grafana_synthetic_monitoring_probes.main[0].probes["Atlanta"],
    data.grafana_synthetic_monitoring_probes.main[0].probes["Frankfurt"],
    data.grafana_synthetic_monitoring_probes.main[0].probes["Tokyo"],
  ] : []
}

resource "grafana_synthetic_monitoring_check" "tripbot" {
  count     = local.sm_enabled ? 1 : 0
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
  count     = local.sm_enabled ? 1 : 0
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
  count     = local.sm_enabled ? 1 : 0
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
  count     = local.sm_enabled ? 1 : 0
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
