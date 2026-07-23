// Grafana Cloud alert rules for the tripbot → OBS broadcast chain.
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

  // Streaming platforms with a per-platform OBS stack (twitch,
  // youtube, …). Drives the dynamic per-platform "stream metrics absent"
  // canary below — add a platform here when it gets its own encoder and it
  // gains lost-visibility coverage automatically. The other stream-health
  // rules self-scale via `by (service_platform)` and don't need this list.
  stream_platforms = ["twitch", "youtube"]

  // Mode gate. AND a stream-health rule's query with this to silence it while
  // the component it watches is intentionally parked — the console scales a
  // platform's obs/mediamtx to 0 in dark/chat-only/off — and arm it only when
  // that component is meant to be running (live). console_platform_component_up
  // is the console's live read of desired replicas, emitted on the app-metrics
  // path; KSM exports the same counts but Grafana Cloud lags/trims them by ~an
  // hour, so the alerts can't join against KSM. The metric is prod-only, so the
  // service_platform join also keeps stage series out (stage never pages).
  //
  // Rules whose result carries a service_platform label join on it; the
  // twitch-only bare-max rules (no service_platform on the result) pin the
  // platform in the gate and join on (). The gate-metric deadman (gate-health
  // group) pages if console_platform_component_up disappears, so a lost gate
  // signal is loud rather than a silent un-arming.
  obs_mode_gate        = "and on (service_platform) (console_platform_component_up{component=\"obs\", deployment_environment=\"prod-1\"} > 0)"
  obs_twitch_mode_gate = "and on () (console_platform_component_up{component=\"obs\", service_platform=\"twitch\", deployment_environment=\"prod-1\"} > 0)"
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
    url                     = data.aws_ssm_parameter.discord_alerts_webhook.value
    use_discord_username    = false // use the webhook's configured username
    disable_resolve_message = false
  }
}

// Independent critical-alert path. A plain webhook POST to an ntfy.sh topic so
// a dead Discord webhook (the 2026-06-15 failure) can't black-hole the page —
// this transport shares no failure domain with Discord. Receives severity=
// critical firings (escalation) + the notification-delivery-failure alert.
// Message formatting is the default Grafana webhook JSON; prettifying
// via ntfy X-Title/X-Priority headers is a tracked follow-up.
resource "grafana_contact_point" "ntfy_critical" {
  name = "ntfy-critical"

  webhook {
    url                     = data.aws_ssm_parameter.ntfy_critical_webhook.value
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
    url                     = data.aws_ssm_parameter.healthchecks_deadman_ping.value
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
  // fires continuously (two deployments share the free-tier budget) and
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
        expr          = "max by (service_name) (go_goroutine_count{service_name=~\"tripbot|onscreens-server\"})"
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
        expr          = "max by (service_name) (go_memory_used_bytes{service_name=~\"tripbot|onscreens-server\"}) - max by (service_name) (go_memory_used_bytes{service_name=~\"tripbot|onscreens-server\"} offset 1h)"
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

// Host-storage alert — the Samsung T5 USB SSD is the Talos UserVolume backing
// every durable PV on the minipc (prod+stage Postgres, NATS JetStream, the vlc
// cache). When the USB link drops the device off the bus, xfs shuts the
// filesystem down and every service on it starts logging "input/output error";
// prod+stage Postgres go CreateContainerError until a node reboot re-enumerates
// the disk. This alerts off Loki rather than the pod-state KSM metrics on
// purpose: those series are dropped by the Mimir active-series cap (see the
// metrics-budget note below), but logs ride a separate, uncapped path. severity
// = critical so it escalates to ntfy (phone) as well as Discord.
resource "grafana_rule_group" "host_storage" {
  name             = "host-storage"
  folder_uid       = grafana_folder.tripbot.uid
  interval_seconds = local.alert_eval_interval_seconds

  rule {
    name           = "minipc T5 SSD I/O fault"
    for            = "0m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "minipc durable SSD is throwing I/O errors (Postgres/NATS/vlc volume)"
      description = "A service on the minipc logged \"input/output error\" — the signature of the Samsung T5 USB SSD dropping off the bus (xfs shuts down; prod+stage Postgres go CreateContainerError). Recovery: reboot the node to re-enumerate the disk and replay the xfs log — `talosctl -e minipc.whereisdana.today -n minipc.whereisdana.today reboot` (reboot does NOT wipe the UserVolume). The hourly S3 pg_dump is the backstop; the root fix is the physical USB link (USB4/rear port + known-good short cable). Runbook: vault/infra/minipc-ssd-migration-runbook.md."
    }
    labels = {
      severity = "critical"
    }

    data {
      ref_id = "A"
      relative_time_range {
        from = 300
        to   = 0
      }
      datasource_uid = data.grafana_data_source.loki.uid
      model = jsonencode({
        refId         = "A"
        expr          = "sum(count_over_time({cluster=\"adanalife-minipc\"} |= \"input/output error\" [5m]))"
        queryType     = "instant"
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
        expr          = "max by (service_platform, deployment_environment) (rate(obs_stream_output_skipped_frames{service_name=\"tripbot\", deployment_environment=\"prod-1\"}[5m])) ${local.obs_mode_gate}"
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
      service  = "obs"
      // Muted: fires continuously from routine iGPU contention on the shared
      // single-node minipc (co-tenant stage/video-pipeline load) with no
      // per-firing action to take. Kept (still evaluates + shows in the Alerting
      // UI) but routed through the always-on mute timing — see the mute=true
      // sub-route on grafana_notification_policy.root.
      mute = "true"
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
        expr          = "max by (service_platform, deployment_environment) (rate(obs_render_skipped_frames{service_name=\"tripbot\", deployment_environment=\"prod-1\"}[5m])) ${local.obs_mode_gate}"
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
      service  = "obs"
      // Muted: fires continuously from routine iGPU contention on the shared
      // single-node minipc (co-tenant stage/video-pipeline load) with no
      // per-firing action to take. Kept (still evaluates + shows in the Alerting
      // UI) but routed through the always-on mute timing — see the mute=true
      // sub-route on grafana_notification_policy.root.
      mute = "true"
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
        expr          = "max by (service_platform, deployment_environment) (rate(obs_output_skipped_frames{service_name=\"tripbot\", deployment_environment=\"prod-1\"}[5m])) ${local.obs_mode_gate}"
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
        expr          = "max by (service_platform) (avg_over_time(rate(obs_render_skipped_frames{service_name=\"tripbot\", deployment_environment=\"prod-1\"}[5m])[1h:1m])) ${local.obs_mode_gate}"
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
      service  = "obs"
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
        expr          = "max by (service_platform, deployment_environment) (obs_stream_output_congestion{service_name=\"tripbot\", deployment_environment=\"prod-1\"}) ${local.obs_mode_gate}"
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

  // Visibility canary, one per platform: every other stream-health rule uses
  // no_data_state=OK, so if tripbot stops emitting obs_streaming_active entirely
  // (pod crash, broken OTLP push) they all go quiet instead of firing — "lost
  // all visibility" looks identical to "healthy". absent() flips that into an
  // explicit page. no_data_state=OK is correct here: when the series IS present
  // (healthy), absent() returns nothing, which Grafana sees as no-data for ref
  // A — that's the OK case. exec_err=Alerting so a datasource error (also a
  // visibility loss) still pages.
  //
  // The obs_mode_gate keeps this honest against intentional dark: a parked OBS
  // (dark/chat-only/off) makes the series absent too, which would look identical
  // to lost visibility — the gate silences the canary unless the console says
  // this platform's OBS is meant to be up (desired replicas > 0). That's what
  // lets it page again after being parked for exactly this false-positive.
  //
  // One rule per platform because absent() can't be grouped — a single
  // absent(obs_streaming_active{prod-1}) only fires when EVERY platform is gone,
  // so a single-encoder outage (youtube blind while twitch is up) would slip
  // through. Generated from local.stream_platforms so new platforms get
  // coverage automatically.
  dynamic "rule" {
    for_each = toset(local.stream_platforms)
    content {
      name           = "OBS: ${rule.value} stream metrics absent (lost visibility)"
      for            = "5m"
      condition      = "C"
      no_data_state  = "OK"
      exec_err_state = "Alerting"

      annotations = {
        summary     = "No obs_streaming_active from prod ${rule.value} for 5m"
        description = "obs_streaming_active{deployment_environment=\"prod-1\", service_platform=\"${rule.value}\"} has been absent for 5m while the ${rule.value} OBS is meant to be up — tripbot isn't reporting stream state, so every other stream-health rule is blind for that platform. Check the prod ${rule.value} tripbot pod (crashloop? OOM?) and the OTLP push path (pkg/telemetry). This is a lost-visibility page, not a stream-state page."
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
          expr          = "absent(obs_streaming_active{service_name=\"tripbot\", deployment_environment=\"prod-1\", service_platform=\"${rule.value}\"}) ${local.obs_mode_gate}"
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

  rule {
    name           = "OBS: stream reconnecting"
    for            = "1m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "OBS {{ $labels.service_platform }} stream output is reconnecting"
      description = "obs-websocket reports the {{ $labels.service_platform }} stream output has been in the reconnecting state for over 1m."
    }
    labels = {
      severity = "critical"
      service  = "obs"
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
        expr          = "max by (service_platform) (obs_stream_output_reconnecting{service_name=\"tripbot\", deployment_environment=\"prod-1\"}) ${local.obs_mode_gate}"
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
  // obs_streaming_active is emitted by tripbot whenever it's up (if tripbot
  // itself is down, the absent-visibility canary above covers that), so =0
  // cleanly means "not broadcasting". The obs_mode_gate limits this to
  // platforms whose OBS is meant to be up (live), so a console-parked platform
  // (dark/chat-only/off) doesn't page. for=10m so routine OBS restarts / the
  // watchdog's brief StopStream+StartStream / a rolling redeploy self-clear
  // before paging.
  rule {
    name           = "OBS: stream is down (not broadcasting)"
    for            = "10m"
    condition      = "C"
    no_data_state  = "OK" // tripbot not reporting → handled by the absent-visibility canary, not here
    exec_err_state = "Error"

    annotations = {
      summary     = "Prod {{ $labels.service_platform }} OBS has not been streaming for 10m"
      description = "obs_streaming_active{deployment_environment=\"prod-1\", service_platform=\"{{ $labels.service_platform }}\"} has been 0 for 10m while the {{ $labels.service_platform }} OBS is meant to be up — it is not broadcasting (stopped, crashed, or never resumed after a restart) and viewers see nothing. Parking the platform from the console (dark/chat-only/off) disarms this; for a planned stop while it's meant to be live, add a Grafana silence. Otherwise check OBS (the obs-{{ $labels.service_platform }} pod / OBS WebSocket) and start the stream. Distinct from the silent-disconnect alert, which is OBS streaming while the platform shows offline."
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
        expr          = "max by (service_platform) (obs_streaming_active{service_name=\"tripbot\", deployment_environment=\"prod-1\"}) ${local.obs_mode_gate}"
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
  // Twitch-only: the OBS side is scoped to service_platform="twitch" because
  // the only liveness signal we have is tripbot_twitch_channel_live (Twitch).
  // Without that scope, max(obs_streaming_active) would span every platform, so
  // the youtube encoder streaming would mask or fake a twitch silent-disconnect.
  // A youtube equivalent needs a tripbot_youtube_channel_live metric first (the
  // youtube stream is currently unlisted/botless) — tracked separately.
  //
  // Expression: max() drops all labels so the two tripbot gauges
  // (obs_streaming_active and tripbot_twitch_channel_live) subtract cleanly.
  // 1 = silent disconnect; 0 = aligned; -1 = harmless inverse (OBS=0/Twitch=1;
  // impossible to reach steady-state). The obs_twitch_mode_gate silences it
  // when twitch OBS is parked, so a console-dark twitch doesn't page.
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
        expr          = "(max(obs_streaming_active{service_name=\"tripbot\", deployment_environment=\"prod-1\", service_platform=\"twitch\"}) - max(tripbot_twitch_channel_live{service_name=\"tripbot\", deployment_environment=\"prod-1\"})) ${local.obs_twitch_mode_gate}"
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

  // Background-audio dead air — the Twitch music bed (Groove Salad Classic /
  // SomaFM) is not playing. tripbot's audio-fallback watchdog swaps the source
  // onto the local Car Hum bed when SomaFM drops, and the local file plays
  // immediately, so obs_background_audio_playing returns to 1 within ~1m of any
  // SomaFM blip. Sustained 0 for 5m therefore means the source is genuinely
  // silent AND the fallback didn't restore it (fallback file missing, OBS
  // WebSocket wedged, watchdog dead) — real dead air on a 24/7 stream, so
  // critical. Twitch-only: the metric is emitted by tripbot, which only runs
  // the watchdog Twitch-side. no_data=OK so it stays quiet until tripbot#993
  // ships the metric. Silence in Grafana during planned audio-off stretches.
  rule {
    name           = "OBS: Twitch background audio dead air (not playing)"
    for            = "5m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "Twitch background audio has not been playing for 5m"
      description = "obs_background_audio_playing{deployment_environment=\"prod-1\"} has been 0 for 5m — the Twitch music bed (Groove Salad Classic) is silent and the audio-fallback watchdog has NOT restored audio via the local Car Hum bed. Viewers hear dead air. Check the obs-twitch pod / OBS WebSocket and the watchdog logs (audio watchdog: ...). Manual recovery: in noVNC, point the source's local file at /opt/tripbot/assets/carhum/car-hum-idle.flac, or restart the obs-twitch deploy. See vault tripbot/obs/gotchas.md."
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
        expr          = "max(obs_background_audio_playing{service_name=\"tripbot\", deployment_environment=\"prod-1\"}) ${local.obs_twitch_mode_gate}"
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

  // SomaFM down a while — informational. The fallback keeps audible Car Hum on
  // air, so this isn't dead air (the dead-air rule above covers that); it's a
  // heads-up that the stream has been on the local bed instead of the intended
  // music for 20m, i.e. SomaFM's edge has been unreachable for a sustained
  // stretch. Warning → Discord, not a page. for=20m so a brief SomaFM blip the
  // fallback rides through doesn't notify.
  rule {
    name           = "OBS: Twitch on SomaFM fallback bed for 20m"
    for            = "20m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "Twitch background audio has been on the Car Hum fallback for 20m"
      description = "obs_background_audio_on_fallback{deployment_environment=\"prod-1\"} has been 1 for 20m — SomaFM's edge has been unreachable, so the stream is on the local Car Hum bed instead of the SomaFM music. Audio is fine (not dead air); this is a heads-up. Check whether SomaFM is having an outage by streaming a few bytes with a plain GET (icecast rejects Range/HEAD, so curl -I lies): curl -s https://ice.somafm.com/gsclassic-128-mp3 | head -c 1000 | wc -c should be >0. If it's a prolonged outage, nothing to do but wait for the watchdog to swap back. See vault tripbot/obs/gotchas.md."
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
        expr          = "max(obs_background_audio_on_fallback{service_name=\"tripbot\", deployment_environment=\"prod-1\"}) ${local.obs_twitch_mode_gate}"
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

# Relay health — MediaMTX is the RTSP hop between playout (publisher) and OBS
# (reader) per platform. A dead playout pipeline is otherwise indistinguishable
# from a healthy pod (rtspclientsink reports PLAYING without proving data flow,
# and a silent EOS raises no Sentry error), but every one of those black-stream
# modes — pipeline death, crash-loop, wedge-then-exit, pod gone — converges on
# the same relay-side symptom: the dashcam path loses its publisher session.
# MediaMTX flips the path's `state` label off "ready" the moment that happens,
# so the relay is the one vantage point that pages for all of them.
#
# Scope note: a publisher that stays CONNECTED but frozen (session up, no
# frames) keeps state="ready" and does NOT fire this — that's the playhead-
# freeze signal on playout_pipeline_running_time_ms (tracked separately with
# the playout dashboards+alerts item).
resource "grafana_rule_group" "relay_health" {
  name             = "relay-health"
  folder_uid       = grafana_folder.tripbot.uid
  interval_seconds = local.alert_eval_interval_seconds

  // One rule per platform (from local.stream_platforms, same as the obs
  // visibility canaries). state!="ready" instead of state="notReady" so the
  // rule doesn't depend on MediaMTX's exact spelling of the unhealthy state:
  // a healthy path exposes ONLY the state="ready" series, so any series
  // matching state!="ready" means the path exists and has no publisher.
  // no_data=OK keeps it quiet both when healthy (no matching series) and
  // while the relay series are still blocked by the active-series cap
  // (infra#849) — it arms itself automatically once they land.
  dynamic "rule" {
    for_each = toset(local.stream_platforms)
    content {
      name           = "MediaMTX: ${rule.value} dashcam has no publisher"
      for            = "1m"
      condition      = "C"
      no_data_state  = "OK"
      exec_err_state = "Error"

      annotations = {
        summary     = "No publisher on the ${rule.value} dashcam relay for 1m — stream is black"
        description = "MediaMTX reports the `dashcam` path on mediamtx-${rule.value} has no publisher — playout-${rule.value} stopped publishing (pipeline error, crash-loop, wedge-then-exit, or pod down), and the ${rule.value} OBS Dashcam source is showing a frozen frame or black. Check `kubectl -n prod-1 get pods | grep playout-${rule.value}` and its logs. A crash-loop that keeps dying on the same clip is the resume-from-lastplayed corrupt-clip trap — send `!skip` over NATS to advance past the wedged clip. Parking the platform below dark from the console (which scales mediamtx-${rule.value} to 0) disarms this automatically; no manual silence needed."
      }
      labels = {
        severity = "critical"
        service  = "playout"
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
          expr          = "max(paths{name=\"dashcam\", state!=\"ready\", pod=~\"mediamtx-${rule.value}.*\"}) and on () (console_platform_component_up{component=\"mediamtx\", service_platform=\"${rule.value}\", deployment_environment=\"prod-1\"} > 0)"
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

  // Visibility canary, one per platform: the no-publisher rule above is
  // no_data=OK, so if the relay's series vanish entirely (mediamtx pod down —
  // which also blacks the stream — or the scrape/ingest path dead) it goes
  // quiet instead of firing. absent() flips that into an explicit page, same
  // pattern as the vlc stream-metrics canaries.
  dynamic "rule" {
    for_each = toset(local.stream_platforms)
    content {
      name           = "MediaMTX: ${rule.value} relay metrics absent (lost visibility)"
      for            = "5m"
      condition      = "C"
      no_data_state  = "OK"
      exec_err_state = "Alerting"

      annotations = {
        summary     = "No metrics from the ${rule.value} MediaMTX relay for 5m"
        description = "paths{name=\"dashcam\", pod=~\"mediamtx-${rule.value}.*\"} has been absent for 5m — either the mediamtx-${rule.value} pod is down (the ${rule.value} OBS loses its Dashcam feed: black stream) or the scrape/ingest path is broken (the no-publisher page above is blind either way). Check `kubectl -n prod-1 get pods | grep mediamtx-${rule.value}`, then the alloy-metrics logs for err-mimir-max-active-series rejections (the free-tier active-series cap)."
      }
      labels = {
        severity = "critical"
        service  = "playout"
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
          expr          = "absent(paths{name=\"dashcam\", pod=~\"mediamtx-${rule.value}.*\"}) and on () (console_platform_component_up{component=\"mediamtx\", service_platform=\"${rule.value}\", deployment_environment=\"prod-1\"} > 0)"
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
}

# Gate health — the stream-health rules AND their queries with
# console_platform_component_up (the console's per-platform run-state) so a
# parked platform doesn't page. If that metric disappears — console down, its
# scrape/ingest path broken — the gate goes empty and every gated rule silently
# stops firing: exactly the blind spot we're trying to avoid. absent() turns
# that into a loud page instead. Keyed on the obs component (every stream rule
# gates on obs or mediamtx, and the two share the one emitter), so its absence
# means the gate signal is gone. Critical → ntfy.
resource "grafana_rule_group" "gate_health" {
  name             = "gate-health"
  folder_uid       = grafana_folder.tripbot.uid
  interval_seconds = local.alert_eval_interval_seconds

  rule {
    name           = "Stream gate metric absent (mode gating blind)"
    for            = "10m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Alerting"

    annotations = {
      summary     = "console_platform_component_up has been absent for 10m — stream alerts can't tell parked from broken"
      description = "console_platform_component_up{component=\"obs\", deployment_environment=\"prod-1\"} has been absent for 10m. The stream-health rules gate on this metric to follow platform mode, so while it's gone every gated rule evaluates its gate as empty and silently stops firing — a real outage could go unpaged. Check the tripbot-console pod (`kubectl -n prod-1 get pods | grep tripbot-console`), its /metrics endpoint, and the alloy-metrics scrape/ingest path. no_data is OK because a present series makes absent() return nothing."
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
      datasource_uid = data.grafana_data_source.prometheus.uid
      model = jsonencode({
        refId         = "A"
        expr          = "absent(console_platform_component_up{component=\"obs\", deployment_environment=\"prod-1\"})"
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

# Gateway health — the per-platform API gateway sits on tripbot's critical path
# (every Helix / Data-API call routes through it). Two complementary prod-scoped
# signals: the consumer-side reachability gauge tripbot emits (catches "the bot
# can't reach the gateway") and an absent() canary on the gateway's own scraped
# liveness gauge (catches "the gateway process is gone"). Both critical.
resource "grafana_rule_group" "gateway_health" {
  name             = "gateway-health"
  folder_uid       = grafana_folder.tripbot.uid
  interval_seconds = local.alert_eval_interval_seconds

  rule {
    name           = "Gateway: unreachable from tripbot"
    for            = "5m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "tripbot can't reach the platform-gateway"
      description = "tripbot_gateway_up has been 0 for 5m on prod-1 — tripbot's gateway calls are failing at the transport layer (connection refused, timeout, DNS), so Helix/Data-API-backed features (live status, audience, chat send) are degraded. Check the gateway pods (crashloop? OOM? all replicas down?), the in-namespace Service, and any NetworkPolicy. Distinct from the gateway-side absent canary, which fires when the gateway stops reporting entirely."
    }
    labels = {
      severity = "critical"
      service  = "gateway"
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
        expr          = "max(tripbot_gateway_up{service_name=\"tripbot\", deployment_environment=\"prod-1\"})"
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

  rule {
    name           = "Gateway: prod metrics absent (lost visibility)"
    for            = "5m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Alerting"

    annotations = {
      summary     = "No platform_gateway_up from prod-1 for 5m"
      description = "platform_gateway_up{namespace=\"prod-1\"} has been absent for 5m — the gateway genuinely isn't reporting (all replicas down, or the scrape/ingest path is broken). Check `kubectl get pods -n prod-1 | grep gateway`, then the alloy-metrics logs for err-mimir-max-active-series rejections (the free-tier active-series cap). no_data is OK because a present series makes absent() return nothing."
    }
    labels = {
      severity = "critical"
      service  = "gateway"
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
        expr          = "absent(platform_gateway_up{namespace=\"prod-1\"})"
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
