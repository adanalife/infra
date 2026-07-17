# SSM Parameter Store — stage-1 parameters + CI grants.
#
# Migrated from AWS Secrets Manager 2026-07 (SM bills $0.40/secret/month;
# standard-tier parameters are free). The SM containers, their version
# resources, and the per-secret SM CI grants were deleted in the migration's
# final phase; live values were copied by bin/migrate-sm-to-ssm.sh and the
# full pre-migration corpus is archived offline (encrypted, 2026-07-03).
#
# This file is the single bookkeeping point for "what parameters exist in
# this AWS account." Topic files (grafana-cloud.tf, grafana-alerts.tf, etc.)
# keep their consumer-side resources but don't declare parameters.
#
# Per-parameter pattern:
#   - Out-of-band values: an entry in `ssm_parameters` below. The terraform-
#     written placeholder is JSON (`{"placeholder": ...}`) so `jsondecode`
#     consumers and ESO `dataFrom.extract` degrade cleanly while unseeded —
#     same convention as the old SM placeholders. Seed / rotate via:
#       aws-vault exec adanalife-stage -- aws ssm put-parameter \
#         --name /<path> --type SecureString --overwrite --value '<value>'
#     ignore_changes keeps the placeholder from clobbering seeded values.
#   - Terraform-owned values (postgres credentials): a dedicated
#     aws_ssm_parameter writing the real value.
#   - `data "aws_ssm_parameter"` when terraform itself needs the value at
#     plan time (provider auth, alert contact points).
#   - Deliberately UNMANAGED (stream keys, grafana metrics-write): created
#     out-of-band only — a terraform-managed parameter is read
#     (ssm:GetParameter) during refresh, which would hand CI the value. The
#     SSMDenySensitiveParameterRead statement below keeps CI locked out.
#
# First-apply flow in a fresh account (chicken-and-egg with the cloudflare
# provider):
#   1. `task tf:stage:apply` — parameters apply; cloudflare_* resources fail
#      on the placeholder token (expected).
#   2. Seed /stage-1/cloudflare-api-token, plus any other plan-time values.
#      `task stage:allowlist:add-current-ip` populates the allowlist.
#   3. `task tf:stage:apply` again — the provider auths cleanly.

# ============================================================================
# Parameters (out-of-band values)
# ============================================================================
#
# Seeding notes for the non-obvious ones:
#   - stage-1/cloudflare-api-token — token scopes: Zone:Edit, Tunnel:Edit,
#     Pages:Edit, Access:Apps and Policies:Edit, DNS:Edit, Zone Settings:Edit.
#   - stage-1/grafana-cloud-api — JSON {"GRAFANA_CLOUD_URL": "https://<stack>.grafana.net",
#     "GRAFANA_CLOUD_API_TOKEN": ..., "GRAFANA_CLOUD_STACK_SLUG": ...}. Mint a
#     stack service account (Admin role) + token; slug = the URL subdomain.
#   - k8s/grafana-cloud-otlp — JSON {"OTEL_EXPORTER_OTLP_ENDPOINT": ...,
#     "OTEL_EXPORTER_OTLP_HEADERS": "Authorization=Basic <base64(id:key)>"}.
#   - k8s/sentry-* — JSON {"SENTRY_DSN": "https://<key>@<org>.ingest.sentry.io/<project>"}.
#   - k8s/tripbot/twitch-creds — JSON {"TWITCH_CLIENT_ID": ..., "TWITCH_CLIENT_SECRET": ...}
#     (app: tripbot-development). The IRC token lives in the oauth_tokens DB
#     table, not here.
#   - k8s/tripbot/google-maps-api-key — JSON {"GOOGLE_MAPS_API_KEY": "AIza..."}.
#     Stage and prod are distinct keys, restricted to Geocoding + Maps JS.
#   - k8s/tripbot/youtube-creds — JSON {"YOUTUBE_CLIENT_ID": ...,
#     "YOUTUBE_CLIENT_SECRET": ..., optionally "YOUTUBE_CHANNEL_ID": ...}.
#   - k8s/tripbot/discord-alerts-webhook — one webhook URL, two consumers:
#     the Grafana contact point (grafana-alerts.tf, plan-time data source) and
#     tripbot's !report command (via ESO). Same value seeded in adanalife-prod.
#   - k8s/*/ghcr-pull-token — JSON {"username": ..., "token": ...} — a
#     fine-grained GitHub token with read:packages on the package.
#   - ESO picks up new values within 1h; force with
#     `kubectl annotate externalsecret <name> force-sync=$(date +%s) --overwrite`.

locals {
  # parameter name (sans leading /) => description
  ssm_parameters = {
    "stage-1/cloudflare-api-token"         = "Cloudflare API token used by the cloudflare provider."
    "stage-1/grafana-cloud-api"            = "Grafana Cloud admin API token + stack URL/slug for the grafana terraform provider."
    "stage-1/ntfy-critical-webhook"        = "ntfy webhook URL for the Grafana independent critical-alert contact point."
    "stage-1/healthchecks-deadman-ping"    = "healthchecks.io ping URL for the Grafana alerting deadman switch."
    "k8s/grafana-cloud-otlp"               = "Grafana Cloud OTLP endpoint + bearer auth for in-cluster OTel exporters."
    "k8s/sentry-tripbot"                   = "Sentry DSN for the tripbot Go service. Consumed via the SENTRY_DSN env var."
    "k8s/sentry-vlc-server"                = "Sentry DSN for the vlc-server Go service. Consumed via the SENTRY_DSN env var."
    "k8s/sentry-onscreens-server"          = "Sentry DSN for the onscreens-server Go service. Consumed via the SENTRY_DSN env var."
    "k8s/sentry-platform-gateway"          = "Sentry DSN for the platform-gateway service. Consumed via the SENTRY_DSN env var."
    "k8s/sentry-tripbot-console"           = "Sentry DSN for the tripbot-console service. Consumed via the SENTRY_DSN env var."
    "k8s/sentry-video-pipeline"            = "Sentry DSN for the video-pipeline batch jobs. Consumed via the SENTRY_DSN env var."
    "k8s/sentry-playout"                   = "Sentry DSN for the playout service. Consumed via the SENTRY_DSN env var."
    "k8s/tripbot/twitch-creds"             = "Twitch app credentials for tripbot. Keys: TWITCH_CLIENT_ID, TWITCH_CLIENT_SECRET."
    "k8s/tripbot/google-maps-api-key"      = "Google Maps API key for tripbot. Key holds GOOGLE_MAPS_API_KEY."
    "k8s/tripbot/youtube-creds"            = "YouTube OAuth client credentials for tripbot. Keys: YOUTUBE_CLIENT_ID, YOUTUBE_CLIENT_SECRET, optionally YOUTUBE_CHANNEL_ID."
    "k8s/tripbot/discord-alerts-webhook"   = "Discord webhook for infra alerts (Grafana contact point) and tripbot's !report command."
    "k8s/tripbot/discord-bot-token"        = "Discord bot token for the staging tripbot Discord session."
    "k8s/tripbot-console/ghcr-pull-token"  = "GitHub token (read:packages) for pulling the private tripbot-console image from GHCR. Keys: username, token."
    "k8s/platform-gateway/ghcr-pull-token" = "GitHub token (read:packages) for pulling the private platform-gateway image from GHCR. Keys: username, token."
    "k8s/video-pipeline/ghcr-pull-token"   = "GitHub token (read:packages) for pulling the private video-pipeline image from GHCR. Keys: username, token."
  }
}

# Resource label kept as "mirror" from the SM → SSM migration to avoid state
# moves; these are now the canonical (only) home of each value.
resource "aws_ssm_parameter" "mirror" {
  for_each = local.ssm_parameters

  name        = "/${each.key}"
  description = each.value
  type        = "SecureString"
  value       = jsonencode({ placeholder = "set via aws ssm put-parameter" })

  lifecycle {
    ignore_changes = [value]
  }
}

# JSON array of CIDR strings, e.g. ["69.222.113.215/32"]. Edited interactively
# via `task stage:allowlist:add-current-ip`. Consumed by the Cloudflare Access
# policy on tripbot — see cloudflare-tunnel.tf. Separate from the map so the
# placeholder is a valid (empty) allowlist — jsondecode works pre-seed.
# It lived in the mirror map during the migration — keep its state instance.
moved {
  from = aws_ssm_parameter.mirror["stage-1/allowlist-cidrs"]
  to   = aws_ssm_parameter.stage_1_allowlist_cidrs
}

resource "aws_ssm_parameter" "stage_1_allowlist_cidrs" {
  name        = "/stage-1/allowlist-cidrs"
  description = "Allowlisted CIDRs for Cloudflare Access on tripbot.whalecore.com. JSON array of CIDR strings."
  type        = "SecureString"
  value       = "[]"

  lifecycle {
    ignore_changes = [value]
  }
}

# k8s/postgres/credentials — terraform OWNS the value: random_pet generates a
# passphrase-style password, jsonencode wraps it with the user/db fields. ESO
# materializes it into the `postgres-secret` Secret in the stage-1-data
# namespace. stage-1's Postgres is fresh-seeded and disposable, but the
# credential still flows through SSM/ESO (not committed literals) to stay
# symmetric with prod and keep secrets out of git.
#
# Password rotation: bump keepers.rotation_id on random_pet, then apply; after
# the parameter updates, ESO syncs (≤1h or force) and then ALTER USER to bring
# pg_authid in line.

resource "random_pet" "tripbot_db_password" {
  length    = 4
  separator = "-"
}

resource "aws_ssm_parameter" "tripbot_db_credentials" {
  name        = "/k8s/postgres/credentials"
  description = "Postgres credentials for tripbot in stage-1 on adanalife-minipc."
  type        = "SecureString"
  value = jsonencode({
    user     = "tripbot"
    password = random_pet.tripbot_db_password.id
    db       = "tripbot"
  })
}

# ============================================================================
# Unmanaged parameters (deliberately NOT terraform resources)
# ============================================================================
#
# A terraform-managed aws_ssm_parameter is read (ssm:GetParameter) during
# refresh, so managing these would hand CI their values. Create/rotate them
# out-of-band; the Deny statement below keeps CI away.
#
#   - /k8s/obs/twitch-stream-key — Twitch RTMP ingest key for the staging
#     channel. Rotate from the Twitch dashboard (Settings → Stream), then:
#       aws-vault exec adanalife-stage -- aws ssm put-parameter \
#         --name /k8s/obs/twitch-stream-key --type SecureString \
#         --overwrite --value "$STREAM_KEY"
#   - /k8s/obs/youtube-stream-key — YouTube RTMPS key for the staging Brand
#     Account (YouTube Studio → Go live → Stream). Same put-parameter shape.
#   - /k8s/obs/facebook-stream-key — Facebook Live RTMPS key for the stage
#     facebook burn-in Page. Same put-parameter shape.
#   - /k8s/grafana-cloud-metrics-write — Grafana Cloud Mimir/Loki credentials
#     for the in-cluster k8s-monitoring chart (Alloy). JSON:
#     {"PROMETHEUS_HOST": ..., "PROMETHEUS_USERNAME": "<prom instance ID>",
#      "LOKI_HOST": ..., "LOKI_USERNAME": "<loki instance ID>",
#      "TOKEN": "<access-policy token with metrics:write + logs:write>"}
#     Endpoints/IDs from Grafana Cloud Connections; token via Access Policies.
#   - /k8s/external-dns/aws-credentials — the external_dns IAM access key
#     (iam.tf), seeded by hand from the PGP-encrypted outputs. JSON keys:
#     access-key, secret-key.

# ============================================================================
# Plan-time data sources
# ============================================================================
#
# Literal names, NOT aws_ssm_parameter.mirror[...].name: a data source that
# references the mirror resource is deferred to apply time whenever ANY entry
# is added to the map — which leaves a provider fed by it (cloudflare,
# grafana) with an unknown token at plan, and the refresh fails with a
# missing-auth 400. Fresh-account bootstrap: create + seed the parameter
# before the first plan that needs it. KEEP-IN-SYNC: prod-1/secrets.tf.

data "aws_ssm_parameter" "cloudflare_api_token" {
  name = "/stage-1/cloudflare-api-token"
}

data "aws_ssm_parameter" "stage_1_allowlist_cidrs" {
  name = aws_ssm_parameter.stage_1_allowlist_cidrs.name
}

data "aws_ssm_parameter" "grafana_cloud_api" {
  name = "/stage-1/grafana-cloud-api"
}

data "aws_ssm_parameter" "discord_alerts_webhook" {
  name = "/k8s/tripbot/discord-alerts-webhook"
}

data "aws_ssm_parameter" "ntfy_critical_webhook" {
  name = "/stage-1/ntfy-critical-webhook"
}

data "aws_ssm_parameter" "healthchecks_deadman_ping" {
  name = "/stage-1/healthchecks-deadman-ping"
}

# ============================================================================
# CI grants
# ============================================================================

# Terraform reads managed aws_ssm_parameter values (ssm:GetParameter) during
# plan refresh, and CI applies need parameter lifecycle. Read is granted
# account-wide MINUS an explicit Deny on the sensitive unmanaged parameters —
# the Deny is load-bearing: AWS's ReadOnlyAccess (already attached to
# CITerraformRole) includes broad ssm:Get*, so without it CI could read every
# SecureString in the account. Folded into one policy document because
# CITerraformRole is at AWS's 10-managed-policies-per-role cap.
data "aws_iam_policy_document" "ci_terraform_secrets_read" {
  statement {
    sid = "SSMParameterRead"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = [
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/*",
    ]
  }

  statement {
    sid    = "SSMDenySensitiveParameterRead"
    effect = "Deny"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "ssm:GetParameterHistory",
    ]
    resources = [
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/k8s/obs/*",
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/k8s/grafana-cloud-metrics-write",
    ]
  }

  statement {
    sid = "SSMParameterLifecycle"
    actions = [
      "ssm:PutParameter",
      "ssm:DeleteParameter",
      "ssm:AddTagsToResource",
      "ssm:RemoveTagsFromResource",
      "ssm:ListTagsForResource",
    ]
    resources = [
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/*",
    ]
  }
}

resource "aws_iam_policy" "ci_terraform_secrets_read" {
  name        = "AllowCITerraformReadStage1Secrets"
  description = "SSM parameter read + lifecycle for CITerraformRole in stage-1 (read denied on the sensitive unmanaged parameters)."
  policy      = data.aws_iam_policy_document.ci_terraform_secrets_read.json
}

resource "aws_iam_role_policy_attachment" "ci_terraform_secrets_read" {
  role       = module.env_base.ci_terraform_role_name
  policy_arn = aws_iam_policy.ci_terraform_secrets_read.arn
}
