# tripbot's read-only JSON API as a Grafana datasource, for the panels whose
# numbers live in Postgres rather than in a metric.
#
# Per-user lifetime miles is the motivating case: it is a column on `users`,
# and turning it into a Prometheus series would mean one series per viewer,
# forever. tripbot already serves the board at GET /api/stats/community, with
# bots and opted-out accounts filtered exactly as the onscreen leaderboard
# filters them, so the panel reads the same answer the stream shows.
#
# Reached over the same Private Data Source Connect network as the
# VictoriaMetrics datasource: tripbot's /api surface has no Ingress and no
# auth -- it is internal-only by network -- so it answers cluster-side and
# from nowhere else.
resource "grafana_data_source" "tripbot_api" {
  type = "yesoreyeram-infinity-datasource"
  name = "tripbot-api"
  uid  = "tripbot-api"
  url  = local.tripbot_api_url

  private_data_source_connect_network_id = local.pdc_network_id

  json_data_encoded = jsonencode({
    # Without this a panel could name any host and the datasource would proxy
    # to it -- a credential-free open proxy into the cluster for anyone who
    # can edit a panel.
    allowedHosts = [local.tripbot_api_url]
  })
}

locals {
  # prod-1's twitch tripbot. The board is fleet-wide (every platform's rows
  # live in the one database), so one instance answers for all of them.
  tripbot_api_url = "http://tripbot-twitch.prod-1.svc.cluster.local:8080"
}
