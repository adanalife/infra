# Grafana Cloud dashboards-as-code via the grafana/grafana provider.
#
# The provider auths against the Grafana Cloud stack URL using a service
# account API token, both pulled from `stage-1/grafana-cloud-api` (see
# grafana-cloud.tf for the SM container + bootstrap notes). The provider
# block lives here (not providers.tf) so prod-1's symlink to providers.tf
# doesn't inherit a provider it has no resources for — same shape as the
# cloudflare provider in cloudflare-pages.tf.
#
# Dashboard JSON lives in ./grafana-dashboards/. Each `grafana_dashboard`
# resource references a JSON file via `file()`; the JSON is the same
# format Grafana exports from the UI's "Share → Export" flow, with
# datasource UIDs replaced by the DS_ template variables that the
# provider substitutes at apply time. Round-trip flow:
#   1. Build/edit a dashboard in the UI.
#   2. Share → Export → "Export for sharing externally" off, copy JSON.
#   3. Save into grafana-dashboards/<name>.json (or update in place).
#   4. `task tf-stage` to apply.

locals {
  grafana_creds = jsondecode(data.aws_secretsmanager_secret_version.grafana_cloud_api.secret_string)
}

provider "grafana" {
  url  = lookup(local.grafana_creds, "GRAFANA_CLOUD_URL", "https://placeholder.grafana.net")
  auth = lookup(local.grafana_creds, "GRAFANA_CLOUD_API_TOKEN", "placeholder")
}

# Datasource UIDs follow the pattern grafanacloud-<slug>-{prom,logs,traces}
# in Grafana Cloud. Looking up by name returns the live UID, which the
# dashboard JSON interpolates via the DS_PROMETHEUS / DS_LOKI / DS_TEMPO
# template variables.
data "grafana_data_source" "prometheus" {
  name = "grafanacloud-${lookup(local.grafana_creds, "GRAFANA_CLOUD_STACK_SLUG", "placeholder")}-prom"
}

data "grafana_data_source" "loki" {
  name = "grafanacloud-${lookup(local.grafana_creds, "GRAFANA_CLOUD_STACK_SLUG", "placeholder")}-logs"
}

data "grafana_data_source" "tempo" {
  name = "grafanacloud-${lookup(local.grafana_creds, "GRAFANA_CLOUD_STACK_SLUG", "placeholder")}-traces"
}

resource "grafana_folder" "tripbot" {
  title = "TripBot"
}

# Each dashboard JSON file uses sentinel datasource UIDs that the
# `dashboard()` helper below swaps for the real per-stack UIDs at apply
# time. Sentinels (not Grafana's own ${DS_FOO} __inputs syntax) so
# Grafana's own ${variable:format} query interpolation in panel exprs
# keeps working untouched.
#
#   __DS_PROMETHEUS__  →  prometheus DS uid
#   __DS_LOKI__        →  loki DS uid
#   __DS_TEMPO__       →  tempo DS uid
locals {
  dashboard_files = toset([
    "tripbot-service-health",
    "vlc-server-service-health",
    "tripbot-vlc-traffic",
    "postgres-pool",
    "twitch-chat-activity",
    "go-runtime",
    "http-routes",
    "logs-errors",
  ])
  dashboard_substitutions = {
    "__DS_PROMETHEUS__" = data.grafana_data_source.prometheus.uid
    "__DS_LOKI__"       = data.grafana_data_source.loki.uid
    "__DS_TEMPO__"      = data.grafana_data_source.tempo.uid
  }
}

resource "grafana_dashboard" "tripbot" {
  for_each = local.dashboard_files
  folder   = grafana_folder.tripbot.uid
  config_json = replace(
    replace(
      replace(
        file("${path.module}/grafana-dashboards/${each.key}.json"),
        "__DS_PROMETHEUS__", local.dashboard_substitutions["__DS_PROMETHEUS__"]
      ),
      "__DS_LOKI__", local.dashboard_substitutions["__DS_LOKI__"]
    ),
    "__DS_TEMPO__", local.dashboard_substitutions["__DS_TEMPO__"]
  )
}
