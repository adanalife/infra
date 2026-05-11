# AWS Secrets Manager — prod-1 SM containers + CI lifecycle grants.
#
# KEEP-IN-SYNC sibling of terraform/stage-1/secrets.tf. Per-env values
# differ (descriptions, naming prefixes); the shape (container/version/data
# pattern, CI lifecycle, ARN list) is kept structurally identical.
#
# Deviations from stage-1 (intentional):
#   - No `stage_1_allowlist_cidrs` equivalent: prod-1 doesn't run a
#     Cloudflare Tunnel in this pass, so the Access-policy allowlist
#     isn't needed. Re-introduce alongside the tunnel when that ships.
#   - `grafana_cloud_api` exists but has no `data` source: `grafana.tf`
#     (dashboards-as-code) stays in stage-1 against the shared Grafana
#     Cloud stack. The SM container is here for symmetry / readiness;
#     no terraform-side consumer reads it today.
#
# See stage-1/secrets.tf header for the full per-secret pattern and
# first-apply flow.

# ============================================================================
# Cloudflare
# ============================================================================

resource "aws_secretsmanager_secret" "cloudflare_api_token" {
  name        = "prod-1/cloudflare-api-token"
  description = "Cloudflare API token used by the cloudflare provider. Scopes: Zone:Edit, Tunnel:Edit, Pages:Edit, Access:Apps and Policies:Edit, DNS:Edit, Zone Settings:Edit."
}

resource "aws_secretsmanager_secret_version" "cloudflare_api_token" {
  secret_id     = aws_secretsmanager_secret.cloudflare_api_token.id
  secret_string = "placeholder — set via aws secretsmanager put-secret-value"
  lifecycle {
    ignore_changes = [secret_string]
  }
}

data "aws_secretsmanager_secret_version" "cloudflare_api_token" {
  secret_id = aws_secretsmanager_secret.cloudflare_api_token.id
}

# ============================================================================
# Grafana Cloud
# ============================================================================

# OTLP credentials for in-cluster OpenTelemetry exporters (future prod tripbot,
# vlc-server). Same shared Grafana Cloud stack as stage-1, so the OTLP endpoint
# is the same but the Access Policy token here should be a separate prod-only
# token so a leak is blast-radius-bounded.
#
# Bootstrap:
#   aws-vault exec adanalife-prod -- aws secretsmanager put-secret-value \
#     --secret-id k8s/grafana-cloud-otlp \
#     --secret-string '{"OTEL_EXPORTER_OTLP_ENDPOINT":"https://otlp-gateway-prod-us-central-0.grafana.net/otlp","OTEL_EXPORTER_OTLP_HEADERS":"Authorization=Basic <base64(instanceID:apiKey)>"}'
resource "aws_secretsmanager_secret" "grafana_cloud_otlp" {
  name        = "k8s/grafana-cloud-otlp"
  description = "Grafana Cloud OTLP endpoint + bearer auth for in-cluster OTel exporters (prod-1 tripbot/vlc-server when they land)."
}

resource "aws_secretsmanager_secret_version" "grafana_cloud_otlp" {
  secret_id     = aws_secretsmanager_secret.grafana_cloud_otlp.id
  secret_string = jsonencode({ placeholder = "set via aws secretsmanager put-secret-value" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Grafana Cloud admin API credentials placeholder. Unused in this pass —
# grafana.tf (dashboards) stays in terraform/stage-1/ against the shared
# stack. Kept here for symmetry and future "lift grafana admin to prod-1
# or terraform/core" work.
resource "aws_secretsmanager_secret" "grafana_cloud_api" {
  name        = "prod-1/grafana-cloud-api"
  description = "Grafana Cloud admin API token + stack URL/slug. UNUSED today — see KEEP-IN-SYNC note at top of file."
}

resource "aws_secretsmanager_secret_version" "grafana_cloud_api" {
  secret_id     = aws_secretsmanager_secret.grafana_cloud_api.id
  secret_string = jsonencode({ placeholder = "set via aws secretsmanager put-secret-value" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Metrics + logs write credentials for the in-cluster grafana-k8s-monitoring
# helm chart. Separate prod token (not shared with stage-1) so cluster-monitoring
# blast radius is per-env. Container only — value populated out-of-band, Alloy
# reads at runtime via ESO.
#
# Bootstrap (after first `task tf:prod:apply`):
#   aws-vault exec adanalife-prod -- aws secretsmanager put-secret-value \
#     --secret-id k8s/grafana-cloud-metrics-write \
#     --secret-string '{
#       "PROMETHEUS_HOST": "https://prometheus-prod-XX-XXX.grafana.net",
#       "PROMETHEUS_USERNAME": "<numeric prom instance ID>",
#       "LOKI_HOST": "https://logs-prod-XXX.grafana.net",
#       "LOKI_USERNAME": "<numeric loki instance ID>",
#       "TOKEN": "<Grafana Cloud Access Policy token with metrics:write + logs:write>"
#     }'
resource "aws_secretsmanager_secret" "k8s_grafana_cloud_metrics_write" {
  name        = "k8s/grafana-cloud-metrics-write"
  description = "Grafana Cloud Mimir/Loki credentials for the in-cluster k8s-monitoring chart. Consumed by Alloy via ESO."

  depends_on = [aws_iam_role_policy_attachment.ci_terraform_grafana_metrics_write_manage]
}

# ============================================================================
# Sentry
# ============================================================================

# Sentry DSNs for prod-1 tripbot + vlc-server. Decision (2026-05-11): separate
# Sentry projects per env, so prod errors don't drown in the staging stream.
# Bootstrap:
#   aws-vault exec adanalife-prod -- aws secretsmanager put-secret-value \
#     --secret-id k8s/sentry-tripbot \
#     --secret-string '{"SENTRY_DSN":"https://<key>@<org>.ingest.sentry.io/<prod-tripbot-project-id>"}'
# and same shape for k8s/sentry-vlc-server with the prod vlc-server project DSN.
resource "aws_secretsmanager_secret" "sentry_tripbot" {
  name        = "k8s/sentry-tripbot"
  description = "Sentry DSN for the tripbot Go service (prod-1 project). Consumed by pkg/errors via SENTRY_DSN env var."
}

resource "aws_secretsmanager_secret_version" "sentry_tripbot" {
  secret_id     = aws_secretsmanager_secret.sentry_tripbot.id
  secret_string = jsonencode({ placeholder = "set via aws secretsmanager put-secret-value" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

resource "aws_secretsmanager_secret" "sentry_vlc_server" {
  name        = "k8s/sentry-vlc-server"
  description = "Sentry DSN for the vlc-server Go service (prod-1 project). Consumed by pkg/errors via SENTRY_DSN env var."
}

resource "aws_secretsmanager_secret_version" "sentry_vlc_server" {
  secret_id     = aws_secretsmanager_secret.sentry_vlc_server.id
  secret_string = jsonencode({ placeholder = "set via aws secretsmanager put-secret-value" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ============================================================================
# Twitch
# ============================================================================

# Twitch app credentials for prod-1 tripbot. Separate Twitch app from stage-1's
# `tripbot-development` — likely `tripbot-production` once minted. Minting is
# gated on the redirect-URI decision per vault/infra/TODO.md:54; container can
# stay placeholder until then.
#
# Bootstrap (once prod Twitch app exists):
#   aws-vault exec adanalife-prod -- aws secretsmanager put-secret-value \
#     --secret-id k8s/tripbot/twitch-creds \
#     --secret-string '{"TWITCH_CLIENT_ID":"...","TWITCH_CLIENT_SECRET":"..."}'
resource "aws_secretsmanager_secret" "tripbot_twitch_creds" {
  name        = "k8s/tripbot/twitch-creds"
  description = "Twitch app credentials for tripbot (prod-1). Keys: TWITCH_CLIENT_ID, TWITCH_CLIENT_SECRET. Consumed by pkg/twitch."
}

resource "aws_secretsmanager_secret_version" "tripbot_twitch_creds" {
  secret_id     = aws_secretsmanager_secret.tripbot_twitch_creds.id
  secret_string = jsonencode({ placeholder = "set via aws secretsmanager put-secret-value" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ============================================================================
# OBS
# ============================================================================

# Twitch RTMP ingest key for the adanalife (production) channel. Container only.
# Bootstrap when prod OBS goes live:
#   aws-vault exec adanalife-prod -- aws secretsmanager put-secret-value \
#     --secret-id k8s/obs/twitch-stream-key --secret-string "$STREAM_KEY"
# Get the key from https://dashboard.twitch.tv/u/adanalife/settings/stream.
resource "aws_secretsmanager_secret" "k8s_obs_twitch_stream_key" {
  name        = "k8s/obs/twitch-stream-key"
  description = "Twitch RTMP stream key for adanalife (production). Consumed by OBS via ESO. Rotate from the Twitch dashboard, then put-secret-value here."

  depends_on = [aws_iam_role_policy_attachment.ci_terraform_twitch_stream_key_manage]
}

# ============================================================================
# CI lifecycle grants
# ============================================================================

# Bulk GetSecretValue for SM containers terraform refreshes during plan.
# See stage-1/secrets.tf for the rationale and matching shape.
data "aws_iam_policy_document" "ci_terraform_secrets_read" {
  statement {
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecretVersionIds",
    ]
    resources = [
      aws_secretsmanager_secret.cloudflare_api_token.arn,
      aws_secretsmanager_secret.grafana_cloud_otlp.arn,
      aws_secretsmanager_secret.grafana_cloud_api.arn,
      aws_secretsmanager_secret.sentry_tripbot.arn,
      aws_secretsmanager_secret.sentry_vlc_server.arn,
      aws_secretsmanager_secret.tripbot_twitch_creds.arn,
    ]
  }
}

resource "aws_iam_policy" "ci_terraform_secrets_read" {
  name        = "AllowCITerraformReadProd1Secrets"
  description = "Read-only access for CITerraformRole to the SM secrets terraform refreshes during plan in prod-1."
  policy      = data.aws_iam_policy_document.ci_terraform_secrets_read.json
}

resource "aws_iam_role_policy_attachment" "ci_terraform_secrets_read" {
  role       = aws_iam_role.ci_terraform.name
  policy_arn = aws_iam_policy.ci_terraform_secrets_read.arn
}

# --- Per-secret lifecycle grants ---

# k8s/obs/twitch-stream-key
data "aws_iam_policy_document" "ci_terraform_twitch_stream_key_manage" {
  statement {
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
      "secretsmanager:UpdateSecret",
    ]
    resources = [
      "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:k8s/obs/twitch-stream-key-*",
    ]
  }
}

resource "aws_iam_policy" "ci_terraform_twitch_stream_key_manage" {
  name        = "AllowCITerraformManageProd1TwitchStreamKey"
  description = "Lifecycle access for CITerraformRole to the k8s/obs/twitch-stream-key SM secret in prod-1 (container only — value stays placeholder via ignore_changes)."
  policy      = data.aws_iam_policy_document.ci_terraform_twitch_stream_key_manage.json
}

resource "aws_iam_role_policy_attachment" "ci_terraform_twitch_stream_key_manage" {
  role       = aws_iam_role.ci_terraform.name
  policy_arn = aws_iam_policy.ci_terraform_twitch_stream_key_manage.arn
}

# k8s/grafana-cloud-metrics-write
data "aws_iam_policy_document" "ci_terraform_grafana_metrics_write_manage" {
  statement {
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
      "secretsmanager:UpdateSecret",
    ]
    resources = [
      "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:k8s/grafana-cloud-metrics-write-*",
    ]
  }
}

resource "aws_iam_policy" "ci_terraform_grafana_metrics_write_manage" {
  name        = "AllowCITerraformManageProd1GrafanaMetricsWrite"
  description = "Lifecycle access for CITerraformRole to the k8s/grafana-cloud-metrics-write SM secret in prod-1 (container only — value stays out-of-terraform)."
  policy      = data.aws_iam_policy_document.ci_terraform_grafana_metrics_write_manage.json
}

resource "aws_iam_role_policy_attachment" "ci_terraform_grafana_metrics_write_manage" {
  role       = aws_iam_role.ci_terraform.name
  policy_arn = aws_iam_policy.ci_terraform_grafana_metrics_write_manage.arn
}
