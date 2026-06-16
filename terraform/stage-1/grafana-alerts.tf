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

// Independent critical-alert path. A plain webhook POST to an ntfy.sh topic so
// a dead Discord webhook (the 2026-06-15 failure) can't black-hole the page —
// this transport shares no failure domain with Discord. Receives severity=
// critical firings (escalation) + the notification-delivery-failure alert.
// Message formatting is the default Grafana webhook JSON for now; prettifying
// via ntfy X-Title/X-Priority headers is a follow-up (see infra TODO).
resource "grafana_contact_point" "ntfy_critical" {
  name = "ntfy-critical"

  webhook {
    url                     = data.aws_secretsmanager_secret_version.ntfy_critical_webhook.secret_string
    http_method             = "POST"
    disable_resolve_message = false
  }
}

// Deadman heartbeat sink. Grafana POSTs to this healthchecks.io ping URL on the
// repeat interval (driven by the always-firing DeadMansSwitch rule); if the
// pings stop, healthchecks.io fires via its own channel. The whole point is
// that this path is OUTSIDE Grafana, so it catches the failures Grafana can't
// self-report (engine stuck, egress dead, token lapsed, Cloud outage).
resource "grafana_contact_point" "healthchecks_deadman" {
  name = "healthchecks-deadman"

  webhook {
    url                     = data.aws_secretsmanager_secret_version.healthchecks_deadman_ping.secret_string
    http_method             = "POST"
    disable_resolve_message = true // every POST is just a ping; resolve pings add nothing
  }
}

// Always-on mute timing. Covers every minute of every day, so any notification
// policy route that references it never delivers. Used to silence a kept-but-
// noisy rule (labelled mute=true): the rule keeps evaluating and shows in the
// Alerting UI, but no notification is sent.
resource "grafana_mute_timing" "always" {
  name = "always-muted"

  intervals {
    times {
      start = "00:00"
      end   = "24:00"
    }
    weekdays = ["sunday:saturday"]
  }
}

resource "grafana_notification_policy" "root" {
  // Default receiver: everything that doesn't match a child route below
  // (i.e. warnings) goes to Discord, same as before.
  contact_point = grafana_contact_point.discord_alerts.name

  // Sane defaults from Grafana's UI: group by folder + alertname so related
  // firings batch, wait briefly before sending so a noisy burst collapses,
  // re-notify hourly for things that stay broken.
  group_by        = ["grafana_folder", "alertname"]
  group_wait      = "30s"
  group_interval  = "5m"
  repeat_interval = "1h"

  // Deadman route FIRST, continue=false: the always-firing DeadMansSwitch rule
  // (labelled deadman=true, no severity) goes ONLY to healthchecks.io and never
  // pollutes Discord. repeat_interval drives the heartbeat cadence — healthchecks
  // should use a grace window comfortably above this (e.g. period 5m / grace 13m).
  policy {
    matcher {
      label = "deadman"
      match = "="
      value = "true"
    }
    contact_point   = grafana_contact_point.healthchecks_deadman.name
    continue        = false
    group_by        = ["alertname"]
    group_wait      = "30s"
    group_interval  = "5m"
    repeat_interval = "5m"
  }

  // Criticals escalate to the independent ntfy path. continue=true so the next
  // sibling (the Discord copy below) also fires — a matched child suppresses the
  // default receiver, so criticals must be re-routed to Discord explicitly to
  // land in both places. group_wait is short so a page isn't delayed.
  policy {
    matcher {
      label = "severity"
      match = "="
      value = "critical"
    }
    contact_point   = grafana_contact_point.ntfy_critical.name
    continue        = true
    group_by        = ["grafana_folder", "alertname"]
    group_wait      = "10s"
    group_interval  = "5m"
    repeat_interval = "30m"
  }

  // The Discord copy of criticals (see note above). continue=false ends routing.
  policy {
    matcher {
      label = "severity"
      match = "="
      value = "critical"
    }
    contact_point   = grafana_contact_point.discord_alerts.name
    continue        = false
    group_by        = ["grafana_folder", "alertname"]
    group_wait      = "30s"
    group_interval  = "5m"
    repeat_interval = "1h"
  }

  // Muted-but-kept alerts (labelled mute=true). The active-series-cap warning
  // fires continuously now that two deployments share the free-tier budget and
  // there's no action to take, so it's silenced via the always-on mute timing
  // while the rule is kept (still visible/firing in the Alerting UI).
  // continue=false so it never falls through to the Discord default receiver.
  policy {
    matcher {
      label = "mute"
      match = "="
      value = "true"
    }
    contact_point   = grafana_contact_point.discord_alerts.name
    continue        = false
    mute_timings    = [grafana_mute_timing.always.name]
    group_by        = ["grafana_folder", "alertname"]
    group_wait      = "30s"
    group_interval  = "5m"
    repeat_interval = "1h"
  }
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
      // Muted: fires continuously now that two deployments share the free-tier
      // active-series budget and there's no action to take. Kept (still visible
      // in the Alerting UI) but routed through the always-on mute timing — see
      // the mute=true sub-route on grafana_notification_policy.root.
      mute = "true"
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

// Alerts that watch the alerting pipeline itself — the gap the 2026-06-15
// incident exposed (rules fired all night, but the Discord webhook was dead, so
// nothing was delivered). Both rules route OFF Discord by design.
resource "grafana_rule_group" "alerting_self" {
  name             = "alerting-self"
  folder_uid       = grafana_folder.tripbot.uid
  interval_seconds = local.alert_eval_interval_seconds

  // Deadman switch: always firing (vector(1) > 0). Routed only to the
  // healthchecks.io contact point, which Grafana pings on the repeat interval.
  // healthchecks.io alerts (via its own independent channel) if the pings stop —
  // catching whole-pipeline death that Grafana cannot self-report. no_data /
  // exec_err both Alerting so a datasource hiccup keeps it "firing" (= keep
  // pinging) rather than silently going green.
  rule {
    name           = "DeadMansSwitch"
    for            = "0s"
    condition      = "C"
    no_data_state  = "Alerting"
    exec_err_state = "Alerting"

    annotations = {
      summary     = "Deadman heartbeat — always firing by design"
      description = "This alert is intentionally always firing; it pings healthchecks.io on the notification repeat interval. If healthchecks.io stops receiving pings, the Grafana alerting pipeline itself is down (eval engine stuck, egress blocked, API token lapsed, or a Grafana Cloud outage) and healthchecks.io will page via the independent ntfy channel. Nothing to do unless healthchecks.io fires."
    }
    labels = {
      deadman = "true"
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
        expr          = "vector(1)"
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

  // Notification-delivery failure: fires when Grafana Cloud reports it's failing
  // to push notifications to ANY contact point. This is the exact 2026-06-15
  // failure — the Discord webhook was stale and every push 4xx'd while the rules
  // fired into the void. Sourced from the Grafana Cloud usage datasource (the
  // org's own internal alertmanager metrics), and labelled critical so it routes
  // to the independent ntfy path — it must NOT depend on the very delivery path
  // that's broken.
  rule {
    name           = "Grafana: alert notifications failing to deliver"
    for            = "5m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "Grafana is failing to deliver alert notifications to a contact point"
      description = "grafanacloud_instance_alertmanager_notifications_failed_per_second is above zero — alert pushes to one or more contact points are failing, so firings are silently not reaching their channel. Most likely a stale webhook URL. For discord-alerts, the URL lives in SM k8s/tripbot/discord-alerts-webhook (mirrored stage+prod); rotate it and re-run terraform apply so the contact point picks up the new value, then re-test. This rule is delivered via the independent ntfy path so it survives a dead Discord webhook."
    }
    labels = {
      severity = "critical"
      service  = "monitoring"
    }

    data {
      ref_id = "A"
      relative_time_range {
        from = 600
        to   = 0
      }
      datasource_uid = data.grafana_data_source.usage.uid
      model = jsonencode({
        refId         = "A"
        expr          = "sum(grafanacloud_instance_alertmanager_notifications_failed_per_second)"
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

resource "grafana_rule_group" "stream_health" {
  name             = "stream-health"
  folder_uid       = grafana_folder.tripbot.uid
  interval_seconds = local.alert_eval_interval_seconds

  rule {
    name            = "VLC: high lost-frame rate"
    for             = "5m"
    keep_firing_for = "10m" // bursty rate metric — hold firing through dips so it doesn't flap
    condition       = "C"
    no_data_state   = "OK"
    exec_err_state  = "Error"

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
    name            = "OBS: stream output skipping frames"
    for             = "5m"
    keep_firing_for = "10m" // bursty rate metric — hold firing through dips so it doesn't flap
    condition       = "C"
    no_data_state   = "OK"
    exec_err_state  = "Error"

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

  // Encode/render-lag siblings of the stream-output rule above. These two
  // catch contention BEFORE the stream output visibly degrades: render-thread
  // skips mean OBS can't composite at the canvas framerate (GPU contention —
  // the 2026-06-11 stage-starves-prod incident showed up here), output-thread
  // skips mean the encoder lags the render thread (encoder starvation).
  // obs_stream_output_skipped_frames (above) only counts after the stream
  // output drops them — the last symptom, not the first.
  rule {
    name            = "OBS: render thread skipping frames"
    for             = "5m"
    keep_firing_for = "10m" // bursty rate metric — hold firing through dips so it doesn't flap
    condition       = "C"
    no_data_state   = "OK"
    exec_err_state  = "Error"

    annotations = {
      summary     = "OBS render thread is skipping frames"
      description = "Sustained render-thread skipped-frame rate > 0.1/s for 5m. OBS can't composite at the canvas framerate — usually iGPU contention from co-tenant workloads (stage VLC/OBS, dashcam-cv) or host CPU pressure. Check intel_gpu_top on the minipc and what else is running on the node."
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
        expr          = "max(rate(obs_render_skipped_frames{service_name=\"vlc-server\"}[5m]))"
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
          evaluator = { type = "gt", params = [0.1] }
          operator  = { type = "and" }
          query     = { params = ["A"] }
          reducer   = { type = "last", params = [] }
        }]
      })
    }
  }

  rule {
    name            = "OBS: output thread skipping frames"
    for             = "5m"
    keep_firing_for = "10m" // bursty rate metric — hold firing through dips so it doesn't flap
    condition       = "C"
    no_data_state   = "OK"
    exec_err_state  = "Error"

    annotations = {
      summary     = "OBS output thread is skipping frames (encoder lag)"
      description = "Sustained output-thread skipped-frame rate > 0.1/s for 5m. The encoder can't keep up with the render thread — check the encode engine (vaapi on the shared iGPU), co-tenant encode load, and the encoder preset."
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
        expr          = "max(rate(obs_output_skipped_frames{service_name=\"vlc-server\"}[5m]))"
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
          evaluator = { type = "gt", params = [0.1] }
          operator  = { type = "and" }
          query     = { params = ["A"] }
          reducer   = { type = "last", params = [] }
        }]
      })
    }
  }

  // Highpri escalation above the render/output frame-skip warnings: fires only
  // when frame-skip has been HEAVY and SUSTAINED — i.e. the stream has been
  // visibly unwatchable for ~an hour+, not a transient burst. The two warnings
  // above use rate([5m]) + for=5m, which flaps Normal<->Pending<->Alerting every
  // few minutes: the per-clip skip pattern dips to ~0 between clips, resetting
  // the for-timer, so they never produce a single durable "the stream is bad"
  // signal (and would spam fire/resolve pairs if they did notify). This rule
  // averages the 5m render-skip rate over a rolling 1h window, so a short burst
  // can't move the hourly average — it only fires on genuinely sustained
  // degradation and cannot flap. Scoped to prod-1 (a janky stage/dev stream is
  // low-stakes and must not page). Motivating incident: the 2026-06-15 overnight
  // video-pipeline transcode starved the shared iGPU for ~10h (6-9 skipped
  // frames/s), the render warning flapped the whole time, and no durable alert
  // ever fired. Threshold 2/s on the 1h average is ~20x the warning's 0.1/s
  // instantaneous threshold and sits well clear of the ~0 baseline when the
  // iGPU isn't contended.
  rule {
    name           = "OBS: stream unwatchable (sustained heavy frame-skip)"
    for            = "10m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "Prod stream has been dropping frames heavily for ~1h+ (unwatchable)"
      description = "The 1h-average OBS render-thread skipped-frame rate on prod-1 is above 2/s — the stream has been visibly stuttering for an extended period, not a transient burst. Almost always iGPU contention from a co-tenant workload (a video-pipeline transcode/calibrate job, stage VLC/OBS) or sustained host CPU pressure. Check `kubectl get pods -A | grep -E 'transcode|calibrate|pipeline'` and intel_gpu_top on the minipc; stop the offending job to restore real-time encode."
    }
    labels = {
      severity = "critical"
      service  = "obs"
    }

    data {
      ref_id = "A"
      relative_time_range {
        from = 4200
        to   = 0
      }
      datasource_uid = data.grafana_data_source.prometheus.uid
      model = jsonencode({
        refId         = "A"
        expr          = "max(avg_over_time(rate(obs_render_skipped_frames{service_name=\"vlc-server\", deployment_environment=\"prod-1\"}[5m])[1h:1m]))"
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
          evaluator = { type = "gt", params = [2] }
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

  // Visibility canary: every other stream-health rule uses no_data_state=OK, so
  // if prod vlc-server stops emitting entirely (pod crash, broken OTLP push) they
  // all go quiet instead of firing — "lost all visibility" looks identical to
  // "healthy". absent() flips that into an explicit page. no_data_state=OK is
  // correct here: when the series IS present (healthy), absent() returns nothing,
  // which Grafana sees as no-data for ref A — that's the OK case. exec_err=Alerting
  // so a datasource error (also a visibility loss) still pages. Note this is
  // distinct from streaming=0 (intentional dark), which still emits the series.
  rule {
    name           = "OBS: prod stream metrics absent (lost visibility)"
    for            = "5m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Alerting"

    annotations = {
      summary     = "No obs_streaming_active from prod vlc-server for 5m"
      description = "obs_streaming_active{deployment_environment=\"prod-1\"} has been absent for 5m — vlc-server isn't reporting, so every other stream-health rule is blind. Check the prod vlc-server pod (crashloop? OOM?) and the OTLP push path (pkg/telemetry). This is a lost-visibility page, not a stream-state page."
    }
    labels = {
      severity = "critical"
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
        expr          = "absent(obs_streaming_active{service_name=\"vlc-server\", deployment_environment=\"prod-1\"})"
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
        expr          = "max(obs_stream_output_reconnecting{service_name=\"vlc-server\", deployment_environment=\"prod-1\"})"
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

  // The stream-is-down page. Every other rule watches degradation or the
  // half-open divergence (silent disconnect needs obs=1/twitch=0); none catch
  // "OBS isn't broadcasting at all". A cleanly-stopped stream (OBS Stop
  // Streaming, OBS crash, a deploy gap) otherwise sails through silently —
  // found 2026-06-15 when a manual OBS stop produced zero alerts.
  // obs_streaming_active is emitted by vlc-server whenever it's up (if
  // vlc-server itself is down, the absent-visibility canary above covers that),
  // so =0 cleanly means "not broadcasting". for=10m so routine OBS restarts /
  // the watchdog's brief StopStream+StartStream / a rolling redeploy self-clear
  // before paging. The stream is 24/7, so any sustained dark is page-worthy;
  // silence this rule in Grafana during planned stops.
  rule {
    name           = "OBS: stream is down (not broadcasting)"
    for            = "10m"
    condition      = "C"
    no_data_state  = "OK" // vlc-server down → handled by the absent-visibility canary, not here
    exec_err_state = "Error"

    annotations = {
      summary     = "Prod OBS has not been streaming for 10m"
      description = "obs_streaming_active{deployment_environment=\"prod-1\"} has been 0 for 10m — OBS is not broadcasting (stopped, crashed, or never resumed after a restart) and viewers see nothing. If this is planned downtime, add a Grafana silence for this rule. Otherwise check OBS (the obs-twitch pod / OBS WebSocket) and start the stream. Distinct from the silent-disconnect alert, which is OBS streaming while Twitch shows offline."
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
        expr          = "max(obs_streaming_active{service_name=\"vlc-server\", deployment_environment=\"prod-1\"})"
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
        expr          = "max(obs_streaming_active{service_name=\"vlc-server\", deployment_environment=\"prod-1\"}) - max(tripbot_twitch_channel_live{service_name=\"tripbot\", deployment_environment=\"prod-1\"})"
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
        expr          = "max(tripbot_twitch_connected{service_name=\"tripbot\", deployment_environment=\"prod-1\"})"
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
        expr          = "time() - max by (account) (tripbot_twitch_token_expires_at_seconds{service_name=\"tripbot\", deployment_environment=\"prod-1\"})"
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
