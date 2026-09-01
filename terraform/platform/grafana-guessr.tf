# Guessr's dashboard, and the datasource it reads.
#
# Guessr is the one component with no workload in the cluster: it is a
# Cloudflare Pages site whose only store is a D1 the cluster cannot reach, so
# it pushes to neither Prometheus nor Loki and every datasource the dashboards
# in grafana.tf are built on is unavailable to it.
#
# So the numbers come from D1 over Cloudflare's REST API, read by an Infinity
# datasource. The alternative was a public aggregates endpoint on the game
# itself, which would have put every question in a deployed Function and made
# a new question a deploy; this way the SQL lives in the panel. `plays` already
# holds the date, the player, the clip, the distance and the points, so each
# question in guessr's own stats.sql is one query.
#
# The uptime side of the same component is in grafana-synthetic-monitoring.tf.

# The token the Infinity datasource authenticates with: a Cloudflare API token
# scoped to D1 read, created by hand and parked in SSM. Created by hand and not
# by the cloudflare provider on purpose -- a `cloudflare_api_token` resource
# would put the value in this state as a resource attribute rather than as a
# data read, and nothing here needs to mint one on a schedule.
locals {
  cloudflare_d1_token = data.aws_ssm_parameter.cloudflare_d1_read.value
  # Identifiers, not credentials: reaching a database still needs the token
  # above. Cloudflare's own documented setup keeps these in a committed
  # wrangler config, which is where these two are read from
  # (guessr/wrangler.d1.jsonc).
  guessr_d1_production = "121f1d0c-5212-482e-bbc2-ceab1084f279"
}

# Base URL stops at the account, so a panel names the database it is asking
# about in its own path -- which is what lets one datasource serve a production
# panel and a staging one side by side.
resource "grafana_data_source" "guessr_d1" {
  type = "yesoreyeram-infinity-datasource"
  name = "guessr-d1"
  uid  = "guessr-d1"
  url  = "https://api.cloudflare.com/client/v4/accounts/${var.cloudflare_account_id}/d1/database"

  json_data_encoded = jsonencode({
    auth_method = "bearerToken"
    # Without this the datasource will proxy a query to any host a panel names,
    # which is a credential-bearing open proxy for anyone who can edit a panel.
    allowedHosts = ["https://api.cloudflare.com"]
  })

  secure_json_data_encoded = jsonencode({
    bearerToken = local.cloudflare_d1_token
  })
}

resource "grafana_folder" "guessr" {
  title = "Guessr"
}

resource "grafana_dashboard" "guessr" {
  folder = grafana_folder.guessr.uid
  # sensitive() for the same reason as the tripbot dashboards in grafana.tf:
  # the diff is a thousand lines of JSON that drowns out the rest of a plan.
  config_json = sensitive(replace(
    file("${path.module}/grafana-dashboards/guessr.json"),
    "__D1_PRODUCTION__", local.guessr_d1_production
  ))
}
