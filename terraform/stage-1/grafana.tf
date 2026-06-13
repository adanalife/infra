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
#   4. `task tf:stage:apply` to apply.

locals {
  grafana_creds = jsondecode(data.aws_secretsmanager_secret_version.grafana_cloud_api.secret_string)
}

provider "grafana" {
  url  = lookup(local.grafana_creds, "GRAFANA_CLOUD_URL", "https://placeholder.grafana.net")
  auth = lookup(local.grafana_creds, "GRAFANA_CLOUD_API_TOKEN", "placeholder")

  # Synthetic Monitoring — requires GRAFANA_SM_URL + GRAFANA_SM_ACCESS_TOKEN in the
  # stage-1/grafana-cloud-api SM blob (see grafana-synthetic-monitoring.tf for the
  # bootstrap runbook). Uses placeholder defaults so plan doesn't error before seeding.
  sm_url          = lookup(local.grafana_creds, "GRAFANA_SM_URL", "https://synthetic-monitoring-api.grafana.net")
  sm_access_token = lookup(local.grafana_creds, "GRAFANA_SM_ACCESS_TOKEN", "placeholder")
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

# Stack-billing datasource. Exposes the grafanacloud_* metrics (active series,
# log volume, billable users, etc.) that Grafana Cloud emits about the stack
# itself — used for the metrics-budget alert.
data "grafana_data_source" "usage" {
  name = "grafanacloud-usage"
}

resource "grafana_folder" "tripbot" {
  title = "TripBot"
}

# Experimental dashboards that demo visualization techniques — heatmaps,
# state timelines, Paretos, direct labeling, small multiples — on real
# tripbot/vlc data. Once a technique earns its keep the panel is
# promoted into one of the canonical dashboards in the TripBot folder
# and the experiment retired.
resource "grafana_folder" "lab" {
  title = "Lab"
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
  # Filenames carry no sort-order number — ordering lives in each dashboard's
  # title ("NN — Name"), which is what Grafana sorts on. This keeps a reorder
  # to a one-line title edit instead of a file rename + state move. Listed
  # here in display order for readability only (a set is unordered).
  dashboard_files = toset([
    "launch-stream-at-a-glance",
    "stream-health-vlc-server-to-obs",
    "service-health-tripbot",
    "service-health-vlc-server",
    "service-health-onscreens-server",
    "igpu-performance", # hand-built for the Iris Xe (engine-util + frequency); the integrated GPU only emits 4 of xpumanager's metrics, so the vendored discrete-GPU dashboard couldn't populate
    "twitch-chat-activity",
    "logs-and-errors",
    "go-runtime",
    "postgres-pool",
    "tripbot-to-vlc-traffic",
    "http-routes",
    "application-latency-commands-and-db",
    "platform-services",
    # Community dashboards from grafana.com, vendored as JSON so the
    # version is pinned and diffable. Pre-processing applied at vendor
    # time: __inputs/__requires stripped, ${datasource} / ${DS_PROMETHEUS}
    # swapped for the project's __DS_PROMETHEUS__ sentinel, .id removed,
    # .uid set to a stable slug.
    "kubernetes-views-global", # grafana.com/dashboards/15757 — modern cluster view
    "kubernetes-views-pods",   # grafana.com/dashboards/15760 — modern pods view
    "node-exporter-full",      # grafana.com/dashboards/1860
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
  # Wrapped in sensitive() so plan/apply renders "(sensitive value)" instead
  # of the full JSON diff — the dashboards are dashboards-as-code from the
  # files in ./grafana-dashboards/, and the noisy multi-thousand-line diffs
  # drown out everything else in the plan.
  config_json = sensitive(replace(
    replace(
      replace(
        file("${path.module}/grafana-dashboards/${each.key}.json"),
        "__DS_PROMETHEUS__", local.dashboard_substitutions["__DS_PROMETHEUS__"]
      ),
      "__DS_LOKI__", local.dashboard_substitutions["__DS_LOKI__"]
    ),
    "__DS_TEMPO__", local.dashboard_substitutions["__DS_TEMPO__"]
  ))
}

locals {
  lab_dashboard_files = toset([
    "visualization-lab",
  ])
}

resource "grafana_dashboard" "lab" {
  for_each = local.lab_dashboard_files
  folder   = grafana_folder.lab.uid
  config_json = sensitive(replace(
    replace(
      replace(
        file("${path.module}/grafana-dashboards/${each.key}.json"),
        "__DS_PROMETHEUS__", local.dashboard_substitutions["__DS_PROMETHEUS__"]
      ),
      "__DS_LOKI__", local.dashboard_substitutions["__DS_LOKI__"]
    ),
    "__DS_TEMPO__", local.dashboard_substitutions["__DS_TEMPO__"]
  ))
}

# Filenames de-numbered 2026-06-02 — the sort-order number now lives only in
# each dashboard's title ("NN — Name", what Grafana sorts on), so reordering
# is a one-line title edit instead of a file rename. UIDs inside the JSON are
# unchanged, so existing dashboard URLs keep working. These moved blocks turn
# the for_each key change (numbered slug → bare slug) into a state-key rename
# rather than a destroy+create; safe to delete after the first apply on every
# env that uses this workspace. (The community kubernetes-views-* and
# node-exporter-full keys were already bare and don't move.)
moved {
  from = grafana_dashboard.tripbot["00-launch-stream-at-a-glance"]
  to   = grafana_dashboard.tripbot["launch-stream-at-a-glance"]
}
moved {
  from = grafana_dashboard.tripbot["01-stream-health-vlc-server-to-obs"]
  to   = grafana_dashboard.tripbot["stream-health-vlc-server-to-obs"]
}
moved {
  from = grafana_dashboard.tripbot["02-service-health-tripbot"]
  to   = grafana_dashboard.tripbot["service-health-tripbot"]
}
moved {
  from = grafana_dashboard.tripbot["03-service-health-vlc-server"]
  to   = grafana_dashboard.tripbot["service-health-vlc-server"]
}
moved {
  from = grafana_dashboard.tripbot["04-service-health-onscreens-server"]
  to   = grafana_dashboard.tripbot["service-health-onscreens-server"]
}
moved {
  from = grafana_dashboard.tripbot["05-twitch-chat-activity"]
  to   = grafana_dashboard.tripbot["twitch-chat-activity"]
}
moved {
  from = grafana_dashboard.tripbot["06-logs-and-errors"]
  to   = grafana_dashboard.tripbot["logs-and-errors"]
}
moved {
  from = grafana_dashboard.tripbot["07-go-runtime"]
  to   = grafana_dashboard.tripbot["go-runtime"]
}
moved {
  from = grafana_dashboard.tripbot["08-postgres-pool"]
  to   = grafana_dashboard.tripbot["postgres-pool"]
}
moved {
  from = grafana_dashboard.tripbot["09-tripbot-to-vlc-traffic"]
  to   = grafana_dashboard.tripbot["tripbot-to-vlc-traffic"]
}
moved {
  from = grafana_dashboard.tripbot["10-http-routes"]
  to   = grafana_dashboard.tripbot["http-routes"]
}
moved {
  from = grafana_dashboard.tripbot["11-application-latency-commands-and-db"]
  to   = grafana_dashboard.tripbot["application-latency-commands-and-db"]
}
moved {
  from = grafana_dashboard.tripbot["12-platform-services"]
  to   = grafana_dashboard.tripbot["platform-services"]
}
moved {
  from = grafana_dashboard.tripbot["13-igpu-performance"]
  to   = grafana_dashboard.tripbot["igpu-performance"]
}
moved {
  from = grafana_dashboard.lab["99-visualization-lab"]
  to   = grafana_dashboard.lab["visualization-lab"]
}
