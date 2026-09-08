# The in-cluster VictoriaMetrics as a Grafana Cloud datasource, reached over
# Private Data Source Connect: the pdc-agent in the minipc's monitoring
# namespace (k8s/monitoring/prod-1/pdc-agent.yaml) holds an outbound SSH
# tunnel to the stack, and Grafana proxies this datasource's queries back
# through it, so the Service URL below resolves cluster-side and nothing is
# exposed inbound.
#
# Why it exists next to grafanacloud-prom: VM holds every series the cluster
# produces — every scraped family and, since the alloy-receiver, every app
# family too, stage-1 included, with no active-series cap — while the cloud
# Mimir tenant keeps only what the keep-list and the OTLP fan-out send it.
# Dashboards that read here cost the cloud nothing. Alert rules stay on
# grafanacloud-prom on purpose: a rule evaluated against a store that lives
# on the minipc reads NoData exactly when the minipc is the problem.
#
# The network id is the PDC network's access-policy id. It is not readable
# with the stack-level token this provider authenticates with (that needs a
# cloud access policy with accesspolicies:read), so it was taken from the
# datasource the UI created with the network selected
# (jsonData.secureSocksProxyUsername) and pinned here.
resource "grafana_data_source" "victoria_metrics" {
  type = "prometheus"
  name = "VictoriaMetrics"
  uid  = "victoria-metrics"
  url  = "http://victoria-metrics.monitoring.svc.cluster.local:8428"

  private_data_source_connect_network_id = "c49a325a-0190-4ee7-9463-b4899956a1e8"

  json_data_encoded = jsonencode({
    # VM speaks the Prometheus HTTP API; "Prometheus" (not "Mimir") keeps
    # Grafana from expecting Mimir-only endpoints.
    prometheusType = "Prometheus"
    # Alloy's default scrape interval is 60s and the OTLP SDKs export every
    # 60s, so a tighter $__rate_interval floor only invents gaps.
    timeInterval = "60s"
    manageAlerts = false
  })
}
