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

  // Streaming platforms, read from the repo's platforms.json rather than
  // restated here. That file is the fleet-wide supported set — generated from
  // the gateway's provider.SupportedPlatforms and synced in via
  // `task platforms:sync` — and it already drives the per-platform mediamtx
  // relay fan-out, so a platform added there gains lost-visibility coverage on
  // the next apply with no edit to this file.
  //
  // Drives the dynamic per-platform "stream metrics absent" canary below, the
  // rule that reports when tripbot stops emitting obs_* at all and every other
  // stream-health rule for that platform silently goes blind. The other
  // stream-health rules self-scale via `by (service_platform)` and don't need
  // the list.
  //
  // Deliberately the desired set, not an observed one: a platform is listed even
  // while parked, because the canary is gated on the console reporting that
  // platform's OBS as meant to be up. Discovering platforms from live metrics
  // instead would be self-defeating — a platform whose telemetry has vanished is
  // exactly what this canary exists to catch, and it would drop out of its own
  // coverage at the moment it broke.
  stream_platforms = jsondecode(file("${path.module}/../../platforms.json"))["platforms"]

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

  // Relay-side variant of the mode gate, for the playout rules. Keyed on the
  // mediamtx component rather than obs: mediamtx is up in both dark and live,
  // and no console mode runs mediamtx without playout, so this arms a playout
  // rule exactly when playout is running AND has a relay to publish into. The
  // chat-map mode is the reason it isn't keyed on playout itself — there playout
  // runs with mediamtx scaled to 0, so it has no publish target and its playhead
  // isn't expected to advance.
  relay_mode_gate = "and on (service_platform) (console_platform_component_up{component=\"mediamtx\", deployment_environment=\"prod-1\"} > 0)"

  // Every console component a mode gate above keys on. The gate-health deadman
  // generates one absent() canary per entry, so a gate keyed on a new component
  // gains its own canary by being added here — the two can't drift into the
  // state where a gate silently un-arms because nothing watches its component.
  gated_components = ["obs", "mediamtx"]
}

// Discord contact point + root notification policy. Wires every alert in this
// file (plus anything else terraform adds to the org) to the same Discord
// channel tripbot's reportCmd posts to.
//
// grafana_notification_policy is a singleton — there's exactly one root policy
// per Grafana Cloud org, and applying this makes terraform own it. Edits in
// the UI will drift and be reverted on the next apply; add sub-policies here,
// not in the UI.
//
// title/message override Grafana's defaults, which render the full label set,
// the query-refid values (`A=1 C=1`) and four boilerplate links — on a phone
// that buries the one sentence worth reading. The push preview shows the
// message content only (the embed carrying the rule link isn't in the
// preview), so the content has to stand alone: one line per firing alert,
// summary annotation plus the platform it broke on, nothing else. Keep the
// summary annotations short for the same reason — the template can only be as
// brief as the sentence it's handed.
resource "grafana_contact_point" "discord_alerts" {
  name = "discord-alerts"

  discord {
    url                     = data.aws_ssm_parameter.discord_alerts_webhook.value
    use_discord_username    = false // use the webhook's configured username
    disable_resolve_message = false

    title   = "{{ .GroupLabels.alertname }}"
    message = <<-EOT
      {{ range .Alerts.Firing }}🔴 {{ .Annotations.summary }}{{ with .Labels.service_platform }} — {{ . }}{{ end }}
      {{ end }}{{ range .Alerts.Resolved }}✅ {{ .Annotations.summary }}{{ with .Labels.service_platform }} — {{ . }}{{ end }}
      {{ end }}
    EOT
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
      description = "A service on the minipc logged \"input/output error\" — the signature of the Samsung T5 USB SSD dropping off the bus (xfs shuts down; prod+stage Postgres go CreateContainerError). Recovery: reboot the node to re-enumerate the disk and replay the xfs log — `talosctl -e minipc.whereisdana.today -n minipc.whereisdana.today reboot` (reboot does NOT wipe the UserVolume). The hourly S3 pg_dump is the backstop; the root fix is the physical USB link (USB4/rear port + known-good short cable)."
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
      # Grafana reflects the model's queryType back onto this attribute at
      # refresh, so leaving it unset here reads as drift on every plan
      # (`query_type = "instant" -> null`) that an apply cannot settle. It is
      # the only rule in this file whose model sets queryType; the rest omit
      # both and match.
      query_type = "instant"
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
      summary     = "OBS stream output is reconnecting"
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
      summary     = "Prod OBS has not been streaming for 10m"
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

  // The #1 stream-health alert: catches the state where OBS reports
  // outputActive=true while the platform shows the channel offline. OBS's
  // built-in reconnect only fires on a drop it detects, so when the far end goes
  // away without the FIN/RST making it back, OBS keeps streaming into the void.
  // First seen in prod on 2026-05-27 ~30h into a session — manual recovery was
  // StopStream+StartStream via OBS WebSocket; tripbot's watchdog automates that
  // for twitch (3-miss debounce, 10m cooldown) and re-mints the reaped room for
  // tiktok (5-miss debounce, 30m cooldown — a re-mint costs a fresh LIVE that
  // viewers have to rejoin, so it is slower to reach for). This alert fires
  // regardless of the watchdog so we know immediately, not after the detection
  // lag + recovery sequence — and on the platforms with no watchdog it is the
  // only thing that reports the state at all.
  //
  // Per-platform, keyed on tripbot_channel_live: every tripbot stamps its series
  // with service_platform, so one rule covers every encoder and a new platform
  // arrives covered as soon as it reports liveness. The platforms that need this
  // most are the ones with no preview window — TikTok pushed into the Streamlabs
  // restream ingest for hours on 2026-07-27 with nothing reporting whether the
  // room behind it was still there.
  //
  // Expression: `by (service_platform)` on both sides keeps the subtraction
  // per-platform, so one encoder's state can't mask or fake another's. Per
  // platform: 1 = silent disconnect; 0 = aligned; -1 = harmless inverse
  // (OBS=0/platform=1, not reachable in steady state). A platform reporting no
  // liveness at all drops out of the match rather than reading as offline — the
  // lost-visibility canary above is what reports that. obs_mode_gate joins on
  // service_platform, so each platform is armed only while the console says its
  // OBS is meant to be up.
  rule {
    name           = "OBS: silent disconnect (platform sees us offline)"
    for            = "3m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "Stream offline while OBS thinks it's streaming"
      description = "obs_streaming_active=1 but tripbot_channel_live=0 for 3m on {{ $labels.service_platform }} — we are streaming into the void and nobody is watching what OBS is sending. Recovery differs by platform. twitch: the RTMP socket is half-open (the platform dropped its end without OBS noticing) and tripbot's watchdog should StopStream+StartStream within ~3-4m; if it doesn't, do it by hand via OBS WebSocket (StopStream, 3s, StartStream) — see tripbot pkg/obs/watchdog. tiktok: reconnecting the push is NOT enough — a room reaped after a push gap longer than the relay target's idleTimeout is gone for good, so the room has to be re-minted; tripbot's watchdog does that through the gateway (stop then start the egress) within ~6-7m, and if it doesn't, do it by hand from the console's TikTok egress controls. youtube: check the broadcast in YouTube Studio, then restart the obs-youtube stream."
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
        expr          = "(max by (service_platform) (obs_streaming_active{service_name=\"tripbot\", deployment_environment=\"prod-1\"}) - max by (service_platform) (tripbot_channel_live{service_name=\"tripbot\", deployment_environment=\"prod-1\"})) ${local.obs_mode_gate}"
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
  // the watchdog actually forced a recovery. Even a single increment is
  // meaningful — the watchdog only fires after a multi-minute debounce,
  // so any counter increase means we genuinely saw the silent-disconnect
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
      description = "tripbot_obs_silent_disconnect_restarts_total{result=\"ok\"} incremented in the last 5m — the watchdog detected OBS thinking it was streaming while the platform reported offline, and forced a recovery that worked: a StopStream+StartStream on twitch and youtube, an egress re-mint on tiktok. The counter is per-platform, so service_platform on the series says which. The stream is back up; check tripbot logs for the recovery sequence and Loki for any pattern across recurrences. A tiktok re-mint means a brand-new LIVE — viewers on the old room had to rejoin."
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
        expr          = "sum(increase(tripbot_obs_silent_disconnect_restarts_total{service_name=\"tripbot\", result=\"ok\"}[5m]))"
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

  // The other half of the pair above, and the page-worthy one. A recovery
  // that keeps failing is a worse outage than one that fires and works, and
  // it used to be the quieter of the two: the counter only moved past the
  // error check, so through the 9h41m outage on 2026-08-05 the watchdog
  // attempted a restart every 60s, failed every time, and this metric read a
  // flat zero. Sentry was the only signal a stream-path recovery loop was
  // dead. Critical rather than warning because nothing is coming back on its
  // own — by definition the automation has already tried and lost.
  //
  // for = 10m, not 1m: a single failed attempt is normal (OBS can still be
  // tearing the output down), so this waits for a pattern rather than paging
  // on the first miss.
  rule {
    name           = "OBS: silent-disconnect recovery is failing"
    for            = "10m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "OBS silent-disconnect watchdog is restarting and not recovering"
      description = "tripbot_obs_silent_disconnect_restarts_total{result=\"failed\"} has been incrementing for 10m — the watchdog is detecting the silent disconnect and its recovery is not landing, so the stream is dark right now and nothing automated is going to fix it. The counter is per-platform, so service_platform on the series says which. Restarting the OBS output is the only move this watchdog has, so a sustained failure means the fault is below it: check whether OBS itself is wedged (obs_streaming_active=1 with the output emitting no frames is the giveaway — a mechanically-successful StartStream resets the miss counter and the loop starts over), and whether anything the render pipeline depends on is hung. Bouncing the OBS pod is the escalation."
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
        expr          = "sum(increase(tripbot_obs_silent_disconnect_restarts_total{service_name=\"tripbot\", result=\"failed\"}[5m]))"
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


  // The wedged-encoder case: OBS reports the output active, the RTMP socket is
  // healthy, and the encoder is pushing nothing. On 2026-08-05 a hung NFS mount
  // blocked the render pipeline for 9h41m while outputActive stayed 1, so every
  // rule keyed on "is OBS streaming" read green and the silent-disconnect
  // watchdog's ~45 restarts each reconnected to ingest and then emitted zero
  // frames — mechanically successful, so they page as result="ok" rather than
  // as the failure they were.
  //
  // The discriminator is the frame counter itself: obs_stream_output_total_frames
  // climbs at the encoder's framerate whenever anything is actually going out,
  // and sits perfectly still when it isn't. max_over_time - min_over_time rather
  // than increase(): the gauge is per-stream-start, so it resets to zero on a
  // restart, and a spread reads that reset as a large positive rather than as a
  // counter rollover to extrapolate.
  //
  // Gated on obs_streaming_active = 1 so the two states this must not fire on
  // stay excluded — a stream deliberately stopped, and an OBS the poller can't
  // reach (it publishes streaming=0 and leaves the frame gauge at its last
  // value, which would otherwise look exactly like a wedge).
  //
  // Critical, and separate from the recovery-is-failing rule: the remedy differs.
  // Restarting the OBS *output* is the only move the watchdog has and it cannot
  // help here, so this one names the pod bounce.
  rule {
    name           = "OBS: encoder wedged (output active, no frames)"
    for            = "5m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "OBS says it is streaming but has sent no frames for 15m"
      description = "obs_stream_output_total_frames has not advanced in 10m while obs_streaming_active is 1 — OBS holds the output open and the encoder is producing nothing, so the stream is dark while every 'is it streaming' signal reads healthy. service_platform on the series says which platform. Restarting the OBS output will not fix this and the silent-disconnect watchdog can do nothing else: the fault is below the output, in the render pipeline or something it blocks on (a hung NFS mount did this for 9h41m on 2026-08-05). Bounce the OBS pod for that platform, then look for what the render thread was waiting on."
    }
    labels = {
      severity = "critical"
      service  = "obs"
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
        expr          = "max by (service_platform) (max_over_time(obs_stream_output_total_frames{service_name=\"tripbot\", deployment_environment=\"prod-1\"}[10m]) - min_over_time(obs_stream_output_total_frames{service_name=\"tripbot\", deployment_environment=\"prod-1\"}[10m])) and on (service_platform) (max by (service_platform) (obs_streaming_active{service_name=\"tripbot\", deployment_environment=\"prod-1\"}) == 1) ${local.obs_mode_gate}"
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
    name           = "Tripbot: disconnected from Twitch chat"
    for            = "5m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "Tripbot has not been receiving Twitch chat for 5m"
      description = "tripbot_twitch_connected has been 0 for 5m — the bot is not receiving chat. Readiness does not gate on the chat connection, so the pod is healthy but silent. Chat reaches tripbot over gateway-twitch's inbound poll: compare against platform_gateway_chat_connected to localise the fault (gateway 1 / tripbot 0 puts it in the path between them), check gateway-twitch logs for failing inbound_chat requests, and verify gateway-twitch's Twitch token is still valid."
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

  // EventSub liveness. Real-time follow / subscribe / raid delivery has no other
  // signal: the events themselves are far too sparse to alert on (a flat zero
  // for hours is the normal reading), so tripbot reports the positive instead —
  // how many subscriptions the live session is holding. On 2026-08-18 EventSub
  // was dead on prod for 7.5h with the pod Ready, tripbot_channel_live at 1 and
  // nothing firing; two Sentry issues at one event each were the only trace.
  //
  // Not mode-gated. Follows and subs arrive in every console mode, including
  // chat-only with OBS scaled to 0, so gating on the obs component would blind
  // this exactly where chat is the whole product.
  //
  // for=15m clears both self-healing cases: a socket drop redials in ~10s, and
  // a rotated broadcaster token is picked up on the next 5m token reload
  // (tripbot#1402). What survives 15m needs a human.
  rule {
    name           = "Tripbot: EventSub holds no subscriptions"
    for            = "15m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "Tripbot is receiving no real-time Twitch events"
      description = "tripbot_eventsub_subscriptions{result=\"ok\"} has been 0 for 15m — no follower, subscriber, gift, resub or raid event is reaching the bot, so none of those chat shouts will fire. The loop redials every 5m on its own, so 15m of zero means redialing is not helping: the broadcaster grant is revoked or the oauth_tokens row is missing. Re-consent via the platform-gateway flow (surfaced in tripbot-console's auth card), then confirm the gauge returns to 6. Loki `eventsub` lines on tripbot-twitch carry the reason: `broadcaster token rejected` is a refused token, `skipping eventsub` means the row never loaded. Note the chat connection is independent — chat can be fine while this is dead."
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
        expr          = "max(tripbot_eventsub_subscriptions{service_name=\"tripbot\", deployment_environment=\"prod-1\", result=\"ok\"})"
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

  // The partial-grant sibling of the rule above, and the failure that is easier
  // to miss: a broadcaster token short one scope still subscribes to everything
  // else, so only the event types needing that scope go dead. In July 2026 that
  // killed follower announcements for eight days while the other five
  // subscriptions worked, tokenRejected never tripped, and the console's auth
  // card rendered the token healthy the whole time.
  //
  // Gated on result="ok" > 0 so a wholly refused token pages once, as the
  // critical rule above, rather than twice. Warning severity because the
  // channel is still mostly working — but the fix is the same re-consent, and
  // nothing else reports it.
  rule {
    name           = "Tripbot: EventSub subscription refused"
    for            = "15m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "Twitch is refusing one of tripbot's EventSub subscriptions"
      description = "tripbot_eventsub_subscriptions{result=\"denied\"} has been above 0 for 15m while others are held — the broadcaster grant is missing a scope, so the event types needing it are silently dead and the rest keep working. A token refresh cannot fix this: it returns the original grant's scope set, so a short grant stays short through unlimited healthy rotations. Only a re-consent widens it. Which subscription failed is in Loki: `eventsub subscribe failed` on tripbot-twitch names the `event`. channel.follow v2 needs moderator:read:followers, channel.subscribe / .end / .gift / .message need channel:read:subscriptions; channel.raid needs no scope, so its failure means the token itself is bad."
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
        expr          = "max(tripbot_eventsub_subscriptions{service_name=\"tripbot\", deployment_environment=\"prod-1\", result=\"denied\"}) and on () (max(tripbot_eventsub_subscriptions{service_name=\"tripbot\", deployment_environment=\"prod-1\", result=\"ok\"}) > 0)"
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

  // Album bed dead air — the album is the live bed and its play order is empty.
  // This is a different failure from the two SomaFM rules above, which watch
  // obs_background_audio_playing: that gauge is OBS's view of the *source*, and
  // here it reads perfectly healthy — OBS is playing a track. What's broken is
  // that nothing queues the next one, so the stream goes silent the instant the
  // current track ends, with no error, no log line, and a green source. That is
  // how prod TikTok lost eight minutes on 2026-07-29 before anyone noticed, and
  // the only way to see it at the time was reading OBS mp3-decoder lines.
  //
  // album=1 AND tracks=0 is the whole condition. Both gauges are written inside
  // beds.Store on every bed switch and at startup detection — including the arm
  // where reading OBS fails — so they always agree with what the console's
  // now-playing line and !song report.
  //
  // Every platform, not Twitch-only: the album is TikTok's default bed and any
  // platform can be switched onto it from the console. Hence obs_mode_gate
  // rather than obs_twitch_mode_gate — a parked platform's tripbot keeps running
  // and reports a bed it cannot actually play, so gating per-platform on
  // console_platform_component_up is what keeps those instances quiet.
  //
  // for=2m, shorter than the 5m SomaFM rule: silence starts the moment a track
  // ends, so the wait exists only to ride out a switch caught mid-write, not to
  // confirm a sustained condition. critical for the same reason dead air on the
  // Twitch bed is — a music-led slow-TV stream with no music is off the air.
  rule {
    name           = "OBS: album bed dead air (empty play order)"
    for            = "2m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "Album background-audio bed is on air with an empty play order"
      description = "tripbot_background_audio_bed{bed=\"album\"} is 1 while tripbot_background_audio_album_tracks is 0 — the album bed is selected but no tracks are queued, so the stream falls silent when the current track ends and OBS reports nothing wrong. Usual cause: tripbot came up while OBS was already on the album bed and never built a play order. Recovery: re-pick the bed in the console (that path rescans the share), or !audio album from chat as an admin. If the share itself is the problem, check the obs-music PVC is Bound. See vault tripbot/monitoring.md and obs/gotchas.md."
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
        expr          = "max by (service_platform, deployment_environment) (tripbot_background_audio_bed{service_name=\"tripbot\", deployment_environment=\"prod-1\", bed=\"album\"}) == 1 and on (service_platform) (max by (service_platform) (tripbot_background_audio_album_tracks{service_name=\"tripbot\", deployment_environment=\"prod-1\"}) == 0) ${local.obs_mode_gate}"
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
# frames) keeps state="ready", so the no-publisher rule cannot see it. The
# playhead-freeze rule in this group covers that half, off
# playout_pipeline_running_time_ms; the two together cover both ways the
# dashcam feed goes dead. The NATS rule last in the group watches the control
# plane both of their runbooks depend on to recover.
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

  // The frozen-publisher half of the no-publisher page above. When the pipeline
  // wedges without tearing down the RTSP session, MediaMTX keeps the path
  // state="ready" and the reader keeps pulling — the last frame just never
  // changes, so a black/frozen stream reads as healthy from every other
  // vantage point. playout_pipeline_running_time_ms is the one signal that
  // proves media is moving: it advances ~1000ms per wallclock second while the
  // pipeline holds realtime, so a flat window means the playhead has stopped.
  //
  // increase() rather than deriv(): the gauge resets to ~0 when a new pipeline
  // starts, and increase()'s counter-reset handling scores that as forward
  // progress instead of the sharp negative slope deriv() would see, so a
  // restart or a redeploy can't page as a freeze. A pod with too little history
  // to compute an increase drops out of the result for the same reason.
  //
  // Threshold with margin instead of == 0: a healthy 5m window yields ~300000ms,
  // so 10000ms (10s of advance, 3% of realtime) sits two orders of magnitude
  // below healthy and well below even a badly-degraded-but-progressing pipeline.
  // The margin absorbs sampling jitter at the window edges without needing the
  // counter to be exactly flat.
  //
  // Per service_platform via `by`, so one platform's wedge can't be masked by
  // another holding realtime, and a new platform arrives covered. no_data=OK:
  // a parked or crashed playout stops reporting entirely, which is the
  // no-publisher rule's page, not this one.
  rule {
    name           = "Playout: playhead frozen (stream is a still frame)"
    for            = "5m"
    condition      = "C"
    no_data_state  = "OK" // playout not reporting → the no-publisher rule pages, not this
    exec_err_state = "Error"

    annotations = {
      summary     = "Playout playhead frozen for 5m — the dashcam feed is a still frame"
      description = "playout_pipeline_running_time_ms on playout-{{ $labels.service_platform }} advanced less than 10s over a 5m window while the {{ $labels.service_platform }} relay is meant to be up — the GStreamer pipeline is wedged but still holding its RTSP session, so MediaMTX reports the `dashcam` path healthy and the no-publisher page stays quiet while viewers see a frozen frame. Check `kubectl -n prod-1 logs playout-{{ $labels.service_platform }}` for a stalled decode or a silent EOS, then restart the pod from the console; a pipeline that re-wedges on the same clip is the corrupt-clip trap — send `!skip` over NATS to advance past it. Parking the platform below dark from the console (which scales mediamtx-{{ $labels.service_platform }} to 0) disarms this automatically."
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
        expr          = "min by (service_platform) (increase(playout_pipeline_running_time_ms{service_name=\"playout\", deployment_environment=\"prod-1\"}[5m])) ${local.relay_mode_gate}"
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
          evaluator = { type = "lt", params = [10000] }
          operator  = { type = "and" }
          query     = { params = ["A"] }
          reducer   = { type = "last", params = [] }
        }]
      })
    }
  }

  // The control plane behind the two rules above. Both of their runbooks end in
  // "send `!skip` over NATS", so a dead NATS link makes them unactionable at the
  // moment they fire: playout keeps looping the corpus while every playback
  // command (find/goto/timewarp/skip) is dropped silently, with no Sentry error
  // and no relay-side symptom. playout_nats_connected is 1 while the connection
  // is up and 0 while it's down, including before the first successful connect —
  // the boot race where playout comes up ahead of NATS.
  //
  // Ungated, unlike the playhead rules: NATS matters whenever playout runs, and
  // chat-map mode runs playout with mediamtx parked, so local.relay_mode_gate
  // would disarm the rule in a mode where dropped commands still matter. The
  // gauge is only emitted while playout is running, so series presence is the
  // gate — no_data=OK covers a parked or crashed playout, which the no-publisher
  // rule pages for instead.
  //
  // Per service_platform via `by`, with min so a platform reporting 0 can't be
  // masked by a sibling holding its connection.
  //
  // for=10m rides out a NATS pod restart and the boot race, both of which show
  // a legitimate 0 for a few sampling intervals (the gauge is sampled every 5s).
  // Commands being dropped degrades control without blacking the stream, so
  // severity is warning — Discord only, no ntfy escalation.
  rule {
    name           = "Playout: NATS control plane disconnected"
    for            = "10m"
    condition      = "C"
    no_data_state  = "OK" // playout not running → the no-publisher rule pages, not this
    exec_err_state = "Error"

    annotations = {
      summary     = "Playout on {{ $labels.service_platform }} has been off NATS for 10m — playback commands are being dropped"
      description = "playout_nats_connected has been 0 for 10m on playout-{{ $labels.service_platform }} — the pipeline keeps looping the corpus, but every playback command (`!skip`, find/goto/timewarp) is silently dropped, so the playhead-freeze and no-publisher runbooks can't be carried out. Check the NATS pod (`kubectl -n prod-1 get pods | grep nats`) first, then `kubectl -n prod-1 logs playout-{{ $labels.service_platform }}` for reconnect attempts; playout does not re-resolve NATS on its own if it came up before the server was reachable, so restarting the playout pod clears that case."
    }
    labels = {
      severity = "warning"
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
        expr          = "min by (service_platform) (playout_nats_connected{service_name=\"playout\", deployment_environment=\"prod-1\"})"
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
}

# Gate health — the stream-health rules AND their queries with
# console_platform_component_up (the console's per-platform run-state) so a
# parked platform doesn't page. If that metric disappears — console down, its
# scrape/ingest path broken — the gate goes empty and every gated rule silently
# stops firing: exactly the blind spot we're trying to avoid. absent() turns
# that into a loud page instead.
#
# One rule per gated component, from local.gated_components. absent() can't be
# grouped, so a single canary over both components only fires when the console
# stops emitting entirely — the console emitting obs while dropping mediamtx
# would un-arm both playout playhead-freeze rules with nothing to say so. The
# two components come from one emitter, which is what makes that case unlikely
# and also what would make it invisible. Critical → ntfy.
resource "grafana_rule_group" "gate_health" {
  name             = "gate-health"
  folder_uid       = grafana_folder.tripbot.uid
  interval_seconds = local.alert_eval_interval_seconds

  dynamic "rule" {
    for_each = toset(local.gated_components)
    content {
      name           = "Stream gate metric absent (${rule.value} mode gating blind)"
      for            = "10m"
      condition      = "C"
      no_data_state  = "OK"
      exec_err_state = "Alerting"

      annotations = {
        summary     = "console_platform_component_up{component=\"${rule.value}\"} has been absent for 10m — the rules gated on it can't tell parked from broken"
        description = "console_platform_component_up{component=\"${rule.value}\", deployment_environment=\"prod-1\"} has been absent for 10m. The stream-health rules gate on this metric to follow platform mode, so while it's gone every rule gated on this component evaluates its gate as empty and silently stops firing — a real outage could go unpaged. obs gates the OBS-side rules; mediamtx gates the playout playhead-freeze rules. Check the tripbot-console pod (`kubectl -n prod-1 get pods | grep tripbot-console`), its /metrics endpoint, and the alloy-metrics scrape/ingest path. no_data is OK because a present series makes absent() return nothing."
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
          expr          = "absent(console_platform_component_up{component=\"${rule.value}\", deployment_environment=\"prod-1\"})"
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

# Gateway health — the per-platform API gateway sits on tripbot's critical path
# (every Helix / Data-API call routes through it). Two complementary prod-scoped
# liveness signals: the consumer-side reachability gauge tripbot emits (catches
# "the bot can't reach the gateway") and an absent() canary on the gateway's own
# scraped liveness gauge (catches "the gateway process is gone"). Both critical.
#
# The two warnings after them watch things the gateway can get wrong while
# perfectly alive: withholding errors from Sentry once its hourly cap is hit,
# and holding metadata that disagrees with what the operator saved. Both are
# quiet failures — the first looks like a healthy silence, the second like a
# successful save.
#
# All four scope to prod with namespace, the label the annotation scrape
# attaches — the gateway's metrics arrive that way, not over OTLP. The scrape
# is fresh enough to alert on: measured across the six prod gateways,
# time() - timestamp(platform_gateway_up) sits at 14-54s. The 20min-1h
# staleness worth avoiding belongs to KSM series, not to allowlisted pod
# scrapes, so check time() - timestamp(<metric>) before ruling a scraped
# family out rather than assuming either way.
#
# Note the scrape reaches Grafana Cloud only because the cloud destination's
# metricProcessingRules keep-regex in k8s/monitoring/prod-1/values.yml names
# platform_gateway_* — that allowlist is load-bearing for these rules. Renaming
# the family or narrowing the regex silently drops them, and with
# no_data_state OK a dropped family reads as "nothing wrong".
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
  rule {
    name           = "Gateway: Sentry throttle is dropping errors"
    for            = "5m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "A prod gateway hit its hourly Sentry cap — errors are being thrown away"
      description = "platform_gateway_sentry_events_dropped_total{reason=\"hourly_cap\"} rose on {{ $labels.job }} ({{ $labels.pod }}) — that gateway threw errors away instead of reporting them, so Sentry has gone quiet for a reason that looks exactly like healthy. Read the pod's logs for the window rather than trusting Sentry's issue list, which is missing whatever the cap swallowed. A cap hit almost always means one error repeating fast: find that one and fix it rather than raising the cap. The cooldown label is the ordinary case and deliberately not alerted on — it only says a repeat was withheld inside the fingerprint window. no_data is OK because the counter is absent until a platform-gateway release carries it to prod (prod runs the pinned image, not main)."
    }
    labels = {
      severity = "warning"
      service  = "gateway"
    }

    data {
      ref_id = "A"
      relative_time_range {
        from = 900
        to   = 0
      }
      datasource_uid = data.grafana_data_source.prometheus.uid
      model = jsonencode({
        refId         = "A"
        expr          = "sum by (job, pod) (increase(platform_gateway_sentry_events_dropped_total{reason=\"hourly_cap\", namespace=\"prod-1\"}[15m]))"
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
    name           = "Gateway: platform disagrees with saved metadata"
    for            = "15m"
    condition      = "C"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "{{ $labels.platform }} is holding a different {{ $labels.field }} than the one we saved"
      description = "platform_gateway_metadata_drift has been 1 for 15m on {{ $labels.platform }}/{{ $labels.field }} — the platform is holding something other than the operator's saved value, so an edit that the console reported as saved did not take. The store is write-side only: it records what was last sent, which stops being true when the platform rejects the write. Most likely a missing scope on the write path (the pending Twitch re-consent makes title edits 401 with channel:manage:broadcast absent) or a value truncated upstream past a limit the field declaration does not know about. Check the platform's card in the console — it shows stored beside live — then the gateway pod's logs for the failed write. A value changed in the platform's own UI drifts the same way and is benign; re-save from the console to converge. no_data is OK: an unreachable platform records nothing rather than claiming agreement, and the gauge is absent until a platform-gateway release carries it to prod (prod runs the pinned image, not main)."
    }
    labels = {
      severity = "warning"
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
        expr          = "max by (platform, field) (platform_gateway_metadata_drift{namespace=\"prod-1\"})"
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

// Batch health — the scheduled work that keeps a *future* promise, where the
// symptom of failure arrives days after the cause and looks like nothing at all.
//
// guessr's round-generation CronJob is the whole population so far. It runs
// weekly and keeps the game's schedule topped up; the game goes dark the day
// after its last scheduled date, and nothing about that is loud. publish.sh has
// a depth guard that fails the run when the post-run horizon is thin, and the
// job failing IS that alert — but a guard inside a run cannot fire for a run
// that never happened, which is the failure mode with no other witness.
//
// So the signal is neither "did a job fail" nor "did a job run" but "how long
// since one *succeeded*", which collapses both into one number and needs no
// job-level series at all. See the marker-label exception in
// k8s/monitoring/prod-1/values.yml for how a stage-1 series reaches the cloud
// at all — this alert is the only reason it does.
resource "grafana_rule_group" "batch_health" {
  name             = "batch-health"
  folder_uid       = grafana_folder.tripbot.uid
  interval_seconds = local.alert_eval_interval_seconds

  rule {
    name      = "guessr: round generation has not succeeded in 8 days"
    for       = "1h"
    condition = "C"
    // Alerting, not OK, and deliberately: both series vanishing is the silent
    // blindness this rule exists to prevent — the CronJob deleted, KSM broken,
    // or the values.yml marker exception regressed so the series stops reaching
    // the cloud. It also makes a wrong label selector here fail loudly on the
    // first evaluation instead of never firing, which is the failure mode an
    // alert nobody has seen fire cannot be distinguished from.
    no_data_state  = "Alerting"
    exec_err_state = "Error"

    annotations = {
      summary     = "guessr-rounds last succeeded over 8 days ago — the schedule is not being topped up"
      description = "The weekly guessr-rounds CronJob in stage-1 has not recorded a success in 8 days, so the game's schedule is running down with nothing refilling it. At the weekly cadence and a 14-day horizon this leaves roughly six days before a date has no rounds on it, which is a player-visible dark day. Read the last run with `kubectl -n stage-1 get jobs -l app.kubernetes.io/name=guessr-rounds` and its pod logs; `task schedule:prod` and `task schedule:stage` in the guessr repo say how much runway is actually left. A run that failed the depth guard reports it in the logs as `is scheduled only N days out`. To generate outside the schedule: `kubectl -n stage-1 create job --from=cronjob/guessr-rounds guessr-rounds-manual`. If this fires with no CronJob in the cluster at all, the alert is telling you the object is gone rather than the run is late — check Argo."
    }
    labels = {
      severity = "warning"
      service  = "guessr"
    }

    data {
      ref_id = "A"
      relative_time_range {
        from = 3600
        to   = 0
      }
      datasource_uid = data.grafana_data_source.prometheus.uid
      model = jsonencode({
        refId = "A"
        // `or` on kube_cronjob_created is the floor for a CronJob that has never
        // succeeded: the two metrics carry different __name__ so neither drops
        // the other, and max() then takes the later of "when it last worked" and
        // "when it first existed". Without the fallback a never-run CronJob
        // reads as no-data, which is indistinguishable from a broken pipeline.
        expr          = "time() - max(kube_cronjob_status_last_successful_time{namespace=\"stage-1\", cronjob=\"guessr-rounds\"} or kube_cronjob_created{namespace=\"stage-1\", cronjob=\"guessr-rounds\"})"
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
        // 691200s is 8 days: one missed weekly run plus a day of slack, so a
        // single late or retried run is not a page. Two missed runs is 15 days,
        // past the horizon — this has to fire before that.
        conditions = [{
          type      = "query"
          evaluator = { type = "gt", params = [691200] }
          operator  = { type = "and" }
          query     = { params = ["A"] }
          reducer   = { type = "last", params = [] }
        }]
      })
    }
  }
}
