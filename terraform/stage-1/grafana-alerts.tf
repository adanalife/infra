// Grafana Cloud alert rules for the vlc-server → OBS broadcast chain.
//
// Provisioned via terraform: the rules show up in Grafana's Alerting → Alert
// rules UI under the "TripBot" folder + "stream-health" rule group. The root
// notification policy (defined below) routes every rule to the discord-alerts
// contact point — same Discord channel tripbot's reportCmd posts to.
//
// Each rule follows the standard three-step shape:
//   A) prometheus query (instant), returns the metric
//   C) threshold expression on A, fires when the predicate is true
// No B reducer is needed because the queries are already instant.

locals {
  alert_eval_interval_seconds = 60
}

// Discord contact point + root notification policy. Wires every alert in this
// file (plus anything else terraform adds to the org) to the same Discord
// channel tripbot's reportCmd posts to.
//
// grafana_notification_policy is a singleton — there's exactly one root policy
// per Grafana Cloud org, and applying this makes terraform own it. Edits in
// the UI will drift and be reverted on the next apply; add sub-policies here,
// not in the UI.
resource "grafana_contact_point" "discord_alerts" {
  name = "discord-alerts"

  discord {
    url                     = data.aws_secretsmanager_secret_version.discord_alerts_webhook.secret_string
    use_discord_username    = false // use the webhook's configured username
    disable_resolve_message = false
  }
}

resource "grafana_notification_policy" "root" {
  contact_point = grafana_contact_point.discord_alerts.name

  // Sane defaults from Grafana's UI: group by folder + alertname so related
  // firings batch, wait briefly before sending so a noisy burst collapses,
  // re-notify hourly for things that stay broken.
  group_by        = ["grafana_folder", "alertname"]
  group_wait      = "30s"
  group_interval  = "5m"
  repeat_interval = "1h"
}

// Go-runtime alert rules — catches the two leak shapes most likely to
// bite the bot in production: an unbounded climb in goroutine count
// (a stuck-goroutine leak) and sustained heap growth (a memory leak
// holding references that never get collected). Lives in its own rule
// group so it can be toggled independently of stream-health.
//
// Metric names come from the OTel-runtime exporter pushed via OTLP and
// match what the go-runtime dashboard queries against.
resource "grafana_rule_group" "go_runtime" {
  name             = "go-runtime"
  folder_uid       = grafana_folder.tripbot.uid
  interval_seconds = local.alert_eval_interval_seconds

  rule {
    name           = "Go: goroutine count high"
    for            = "10m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "Goroutine count above 10000 for 10m"
      description = "Sustained goroutine count > 10000 on a tripbot service usually indicates a goroutine leak (a worker started per-request that never returns, a missing ctx-cancel, etc.). Open the go-runtime dashboard for the affected service and pull a goroutine profile from Pyroscope to find the leak site."
    }
    labels = {
      severity = "warning"
      service  = "{{ $labels.service_name }}"
    }

    data {
      ref_id = "A"
      relative_time_range {
        from = 600
        to   = 0
      }
      datasource_uid = data.grafana_data_source.prometheus.uid
      model = jsonencode({
        refId         = "A"
        expr          = "max by (service_name) (go_goroutine_count{service_name=~\"tripbot|vlc-server|onscreens-server\"})"
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
          evaluator = { type = "gt", params = [10000] }
          operator  = { type = "and" }
          query     = { params = ["A"] }
          reducer   = { type = "last", params = [] }
        }]
      })
    }
  }

  rule {
    name           = "Go: heap growing without bound"
    for            = "15m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "Heap grew by more than 100 MB over the last hour"
      description = "Sustained heap growth without bound suggests a memory leak — references being held that never get collected. Open the go-runtime dashboard for the affected service and pull a heap profile (alloc_space + inuse_space) from Pyroscope to find what's accumulating."
    }
    labels = {
      severity = "warning"
      service  = "{{ $labels.service_name }}"
    }

    data {
      ref_id = "A"
      relative_time_range {
        from = 3600
        to   = 0
      }
      datasource_uid = data.grafana_data_source.prometheus.uid
      model = jsonencode({
        refId         = "A"
        expr          = "max by (service_name) (go_memory_used_bytes{service_name=~\"tripbot|vlc-server|onscreens-server\"}) - max by (service_name) (go_memory_used_bytes{service_name=~\"tripbot|vlc-server|onscreens-server\"} offset 1h)"
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
          evaluator = { type = "gt", params = [100000000] }
          operator  = { type = "and" }
          query     = { params = ["A"] }
          reducer   = { type = "last", params = [] }
        }]
      })
    }
  }
}

// Metrics-budget alert — fires when Grafana Cloud's tenant-side count of
// active series climbs toward the free-tier hard cap (15000). Routes to the
// shared discord-alerts contact point.
//
// History: on 2026-05-25 we crossed the 15000 cap and started getting
// err-mimir-max-active-series rejections, which lost samples permanently
// (Alloy retries → err-mimir-too-far-in-past). Cardinality cut in
// [infra#575](https://github.com/adanalife/infra/pull/575/changes) brought us
// back under, but the only signal was a billing email. This alert closes
// that gap. Threshold was originally 12000 (3000 headroom) but the
// post-launch steady-state baseline settled around 12-13K and paged
// continuously — raised to 14000 (1000 headroom) on 2026-05-26 so the
// alert signals genuine drift toward the cap rather than the normal load.
resource "grafana_rule_group" "metrics_budget" {
  name             = "metrics-budget"
  folder_uid       = grafana_folder.tripbot.uid
  interval_seconds = local.alert_eval_interval_seconds

  rule {
    name           = "Grafana Cloud: approaching free-tier active-series cap"
    for            = "15m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "Active series > 14000 for 15m (free-tier hard cap is 15000)"
      description = "Grafana Cloud free tier ingests up to 15000 active series; beyond that, samples are rejected (err-mimir-max-active-series). At 14000+ for 15m there's ~1000-series of headroom — schedule a cardinality cut before ingestion starts failing. Check `topk(30, count by (__name__) ({__name__=~\".+\"}))` for the top contributors."
    }
    labels = {
      severity = "warning"
      service  = "monitoring"
    }

    data {
      ref_id = "A"
      relative_time_range {
        from = 900
        to   = 0
      }
      datasource_uid = data.grafana_data_source.usage.uid
      model = jsonencode({
        refId         = "A"
        expr          = "max(grafanacloud_instance_active_series)"
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
          evaluator = { type = "gt", params = [14000] }
          operator  = { type = "and" }
          query     = { params = ["A"] }
          reducer   = { type = "last", params = [] }
        }]
      })
    }
  }
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
        expr          = "max(rate(obs_stream_output_skipped_frames{service_name=\"vlc-server\"}[5m]))"
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
      service  = "vlc-server"
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
        expr          = "max(obs_stream_output_congestion{service_name=\"vlc-server\"})"
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
      service  = "vlc-server"
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
        expr          = "max(obs_stream_output_reconnecting{service_name=\"vlc-server\"})"
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

  // The #1 stream-health alert: catches the silent half-open RTMP state
  // where OBS reports outputActive=true but Twitch's API shows the channel
  // offline. OBS's built-in reconnect only fires on a detected drop;
  // when Twitch's ingest goes away without the FIN/RST making it back, OBS
  // keeps streaming into the void. First seen in prod on 2026-05-27 ~30h
  // into a session — manual recovery was StopStream+StartStream via OBS
  // WebSocket; tripbot's watchdog automates that (3-miss debounce, 10m
  // cooldown). This alert fires regardless of the watchdog so we know
  // immediately, not after 3 minutes of detection lag + restart sequence.
  //
  // Expression: max() drops all labels so we can subtract across services
  // (obs_streaming_active is on vlc-server, tripbot_twitch_channel_live is
  // on tripbot). 1 = silent disconnect; 0 = aligned; -1 = harmless inverse
  // (OBS=0/Twitch=1; impossible to reach steady-state).
  rule {
    name           = "OBS: silent disconnect (Twitch sees us offline)"
    for            = "3m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "Stream offline on Twitch while OBS thinks it's streaming"
      description = "obs_streaming_active=1 but tripbot_twitch_channel_live=0 for 3m. RTMP socket is silently half-open — Twitch dropped its end and OBS didn't notice. Tripbot's watchdog should StopStream+StartStream within ~3-4m of detection; if it doesn't, run the manual recovery via OBS WebSocket: StopStream then 3s then StartStream. See tripbot pkg/obs/silent_disconnect_watchdog.go."
    }
    labels = {
      severity = "critical"
      service  = "obs"
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
        expr          = "max(obs_streaming_active{service_name=\"vlc-server\"}) - max(tripbot_twitch_channel_live{service_name=\"tripbot\"})"
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

  // Notification rule paired with the silent-disconnect alert: fires when
  // the watchdog actually forced a restart. Even a single increment is
  // meaningful — the watchdog only fires after the 3-minute debounce,
  // so any counter increase means we genuinely saw the silent half-open
  // state in prod. Warning (not critical) because the stream is back by
  // the time this fires; the critical alert above is the page-worthy one.
  rule {
    name           = "OBS: silent-disconnect watchdog forced a restart"
    for            = "1m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "OBS silent-disconnect watchdog auto-recovered a stream"
      description = "tripbot_obs_silent_disconnect_restarts_total incremented in the last 5m — the watchdog detected OBS thinking it was streaming while Twitch reported offline, and forced a StopStream+StartStream. The stream is back up; check tripbot logs for the restart sequence and Loki for any pattern across recurrences."
    }
    labels = {
      severity = "warning"
      service  = "obs"
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
        expr          = "sum(increase(tripbot_obs_silent_disconnect_restarts_total{service_name=\"tripbot\"}[5m]))"
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

  rule {
    name           = "Tripbot: disconnected from Twitch chat"
    for            = "5m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "Tripbot has been disconnected from Twitch chat (IRC) for 5m"
      description = "tripbot_twitch_connected has been 0 for 5m — the bot is not in chat. Readiness no longer gates on the Twitch connection, so the pod is healthy but silent. Check tripbot logs for IRC reconnect errors, verify the bot OAuth token is still valid, and confirm Twitch IRC ingest isn't degraded."
    }
    labels = {
      severity = "critical"
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
        expr          = "max(tripbot_twitch_connected{service_name=\"tripbot\"})"
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
          evaluator = { type = "lt", params = [1] }
          operator  = { type = "and" }
          query     = { params = ["A"] }
          reducer   = { type = "last", params = [] }
        }]
      })
    }
  }

  // Catches the failure mode the "disconnected from Twitch chat" rule above
  // can't see: the IRC connection stays alive (gauge = 1) but the user-access-
  // token has expired or been blanked. Twitch only validates the token on
  // initial PASS, so IRC won't drop; meanwhile Helix calls 401 and the admin
  // panel surfaces a "Sign in as X" banner that needs a human click.
  //
  // The gauge emits 0 for "missing / blanked" — that subtraction yields
  // time(), which is huge-positive, so missing accounts fire the same alert.
  // for=1m debounces normal refresh blips.
  rule {
    name           = "Tripbot: Twitch token expired"
    for            = "1m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "Tripbot's {{ $labels.account }} Twitch token is expired or missing"
      description = "tripbot_twitch_token_expires_at_seconds for the {{ $labels.account }} identity is in the past (or 0 = missing). The bot will need re-auth — open the admin panel and click the 'Sign in as ...' link, or run `task tripbot:auth:bootstrap:{{ $labels.account }}`."
    }
    labels = {
      severity = "critical"
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
        expr          = "time() - max by (account) (tripbot_twitch_token_expires_at_seconds{service_name=\"tripbot\"})"
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
