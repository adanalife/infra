# Grafana Cloud dashboards-as-code via the grafana/grafana provider.
#
# The Grafana Cloud stack is single-tenant — one stack serves stage-1, prod-1
# and development — which is why the whole Grafana surface lives in this
# env-agnostic workspace rather than an env root. The provider auths against
# the stack URL using a service account API token, both pulled from the
# `/platform/grafana-cloud-api` SSM parameter (declared in secrets.tf).
#
# Dashboard JSON lives in ./grafana-dashboards/. Each `grafana_dashboard`
# resource references a JSON file via `file()`; the JSON is the same
# format Grafana exports from the UI's "Share → Export" flow, with
# datasource UIDs replaced by the DS_ template variables that the
# provider substitutes at apply time. Round-trip flow:
#   1. Build/edit a dashboard in the UI.
#   2. Share → Export → "Export for sharing externally" off, copy JSON.
#   3. Save into grafana-dashboards/<name>.json (or update in place).
#   4. `task tf:platform:apply` to apply.

locals {
  grafana_creds = jsondecode(data.aws_ssm_parameter.grafana_cloud_api.value)
}

provider "grafana" {
  url  = lookup(local.grafana_creds, "GRAFANA_CLOUD_URL", "https://placeholder.grafana.net")
  auth = lookup(local.grafana_creds, "GRAFANA_CLOUD_API_TOKEN", "placeholder")
  # Synthetic Monitoring is a separate API behind a separate token; the
  # dashboard credentials above cannot reach it. Set here rather than on an
  # aliased provider because every Grafana resource in this workspace shares
  # one stack. See grafana-synthetic-monitoring.tf for the checks.
  sm_access_token = data.aws_ssm_parameter.grafana_sm_access.value
  # SM access tokens are region-scoped, and the provider's default sm_url is
  # the region-less endpoint, which rejects a regional token as
  # "invalid API token" — a 403 that reads like a bad credential. The region
  # is the tail of the stack's Prometheus host
  # (prometheus-prod-66-prod-us-east-3 → us-east-3).
  sm_url = "https://synthetic-monitoring-api-us-east-3.grafana.net"
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
    "stream-health-playout-to-mediamtx", # playout OTLP push + MediaMTX relay scrape — the dashcam publish path into the relay (playout 0.6.0 metrics)
    "stream-health-obs-to-platforms",    # the egress half: obs_* per-platform frame/bitrate/congestion health, emitted by tripbot
    "service-health-tripbot",
    "service-health-onscreens-server",
    "service-health-platform-gateway", # gateway façade request metrics + the Twitch Helix rate-limit/error panels that replace tripbot's in-process ones at cutover (platform-gateway#14)
    "service-health-tripbot-console",  # the admin live console: SSE clients, its own HTTP surface, and its view of per-platform component health
    "igpu-performance",                # hand-built for the Iris Xe (engine-util + frequency); the integrated GPU only emits 4 of xpumanager's metrics, so the vendored discrete-GPU dashboard couldn't populate
    "twitch-chat-activity",
    "logs-and-errors",
    "go-runtime",
    "postgres-pool",
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
