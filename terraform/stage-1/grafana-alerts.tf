// Grafana Cloud alert rules for the vlc-server → OBS broadcast chain.
//
// Provisioned via terraform: the rules show up in Grafana's Alerting → Alert
// rules UI under the "TripBot" folder + "stream-health" rule group. Without
// a configured notification policy + contact point they fire to Grafana
// Cloud's default contact point (grafana-default-email) — typically a
// no-op for this stack. Wire a real contact point + notification policy
// when alerts should actually page someone.
//
// Each rule follows the standard three-step shape:
//   A) prometheus query (instant), returns the metric
//   C) threshold expression on A, fires when the predicate is true
// No B reducer is needed because the queries are already instant.

locals {
  alert_eval_interval_seconds = 60
}

resource "grafana_rule_group" "stream_health" {
  name             = "stream-health"
  folder_uid       = grafana_folder.tripbot.uid
  interval_seconds = local.alert_eval_interval_seconds

  rule {
    name           = "VLC: high lost-frame rate"
    for            = "5m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "vlc-server is losing frames"
      description = "Sustained lost-frame rate > 1/s for 5m on vlc-server. Check libvlc decode health, host CPU, and disk I/O on the dashcam video store."
    }
    labels = {
      severity = "warning"
      service  = "vlc-server"
    }

    data {
      ref_id = "A"
      relative_time_range {
        from = 300
        to   = 0
      }
      datasource_uid = data.grafana_data_source.prometheus.uid
      model = jsonencode({
        refId         = "A"
        expr          = "max(rate(vlc_player_lost_pictures{service_name=\"vlc-server\"}[5m]))"
        instant       = true
        intervalMs    = 60000
        maxDataPoints = 43200
      })
    }
    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 0
        to   = 0
      }
      model = jsonencode({
        refId      = "C"
        type       = "threshold"
        expression = "A"
        conditions = [{
          type      = "query"
          evaluator = { type = "gt", params = [1] }
          operator  = { type = "and" }
          query     = { params = ["A"] }
          reducer   = { type = "last", params = [] }
        }]
      })
    }
  }

  rule {
    name           = "OBS: stream output skipping frames"
    for            = "5m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "OBS stream output is skipping frames"
      description = "Sustained stream-output skipped-frame rate > 0.5/s for 5m. Encoder is falling behind — check OBS CPU, encoder preset, output bitrate."
    }
    labels = {
      severity = "warning"
      service  = "tripbot"
    }

    data {
      ref_id = "A"
      relative_time_range {
        from = 300
        to   = 0
      }
      datasource_uid = data.grafana_data_source.prometheus.uid
      model = jsonencode({
        refId         = "A"
        expr          = "max(rate(obs_stream_output_skipped_frames{service_name=\"tripbot\"}[5m]))"
        instant       = true
        intervalMs    = 60000
        maxDataPoints = 43200
      })
    }
    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 0
        to   = 0
      }
      model = jsonencode({
        refId      = "C"
        type       = "threshold"
        expression = "A"
        conditions = [{
          type      = "query"
          evaluator = { type = "gt", params = [0.5] }
          operator  = { type = "and" }
          query     = { params = ["A"] }
          reducer   = { type = "last", params = [] }
        }]
      })
    }
  }

  rule {
    name           = "OBS: stream congested"
    for            = "2m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "OBS stream output sustained congestion"
      description = "obs-websocket reports stream-output congestion > 0.5 for 2m. Upstream bandwidth or Twitch ingest is constrained."
    }
    labels = {
      severity = "warning"
      service  = "tripbot"
    }

    data {
      ref_id = "A"
      relative_time_range {
        from = 120
        to   = 0
      }
      datasource_uid = data.grafana_data_source.prometheus.uid
      model = jsonencode({
        refId         = "A"
        expr          = "max(obs_stream_output_congestion{service_name=\"tripbot\"})"
        instant       = true
        intervalMs    = 60000
        maxDataPoints = 43200
      })
    }
    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 0
        to   = 0
      }
      model = jsonencode({
        refId      = "C"
        type       = "threshold"
        expression = "A"
        conditions = [{
          type      = "query"
          evaluator = { type = "gt", params = [0.5] }
          operator  = { type = "and" }
          query     = { params = ["A"] }
          reducer   = { type = "last", params = [] }
        }]
      })
    }
  }

  rule {
    name           = "OBS: stream reconnecting"
    for            = "1m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "OBS stream output is reconnecting"
      description = "obs-websocket reports the stream output has been in the reconnecting state for over 1m."
    }
    labels = {
      severity = "critical"
      service  = "tripbot"
    }

    data {
      ref_id = "A"
      relative_time_range {
        from = 60
        to   = 0
      }
      datasource_uid = data.grafana_data_source.prometheus.uid
      model = jsonencode({
        refId         = "A"
        expr          = "max(obs_stream_output_reconnecting{service_name=\"tripbot\"})"
        instant       = true
        intervalMs    = 60000
        maxDataPoints = 43200
      })
    }
    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 0
        to   = 0
      }
      model = jsonencode({
        refId      = "C"
        type       = "threshold"
        expression = "A"
        conditions = [{
          type      = "query"
          evaluator = { type = "gt", params = [0] }
          operator  = { type = "and" }
          query     = { params = ["A"] }
          reducer   = { type = "last", params = [] }
        }]
      })
    }
  }
}
