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
#   - `gcp_terraform_credentials`: prod-only. YouTube v1 is prod-only, so
#     the google provider (google.tf) and its SA-key credential live in
#     prod-1 alone. Stage-1 has no GCP resources.
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

# OTLP credentials for in-cluster OpenTelemetry exporters (prod tripbot,
# vlc-server). Same shared Grafana Cloud stack as stage-1; the value held
# here matches stage's container byte-for-byte. Per the
# vault/decisions/observability-projects-by-component.md ADR, env separation
# happens via deployment.environment on each event/metric/log, not via
# duplicate access-policy tokens. Bootstrap = copy stage's value into prod's
# container (see the Sentry block below for the for-loop pattern).
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

# Sentry DSNs for prod-1 tripbot + vlc-server. Per the
# vault/decisions/observability-projects-by-component.md ADR, Sentry partitions
# by component (tripbot, vlc-server) with SENTRY_ENVIRONMENT distinguishing
# stage from prod on the event itself — no separate prod projects.
# Bootstrap = copy stage's values into prod's containers:
#   for profile in adanalife-stage adanalife-prod; do
#     aws-vault exec "$profile" -- aws secretsmanager get-secret-value \
#       --secret-id k8s/sentry-tripbot ...
#   done
# Verify cross-env parity with the SHA-256 hash check in
# vault/tripbot/monitoring.md's Sentry section.
resource "aws_secretsmanager_secret" "sentry_tripbot" {
  name        = "k8s/sentry-tripbot"
  description = "Sentry DSN for the tripbot Go service. Consumed by pkg/errors via SENTRY_DSN env var."
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
  description = "Sentry DSN for the vlc-server Go service. Consumed by pkg/errors via SENTRY_DSN env var."
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
# GCP — terraform provider credentials
# ============================================================================

# Service-account JSON key for the `google` terraform provider (see google.tf).
# prod-1-only deviation from the stage-1 KEEP-IN-SYNC sibling: YouTube v1 is
# prod-only, so the GCP provider + its credential live in prod-1 alone. Follows
# the placeholder-plus-out-of-band pattern (vault/decisions/secrets-manager-for-tf-providers).
#
# Bootstrap (one-time; chicken-and-egg — the provider needs creds before it can
# manage anything):
#   1. gcloud iam service-accounts create terraform --project tripbot-prod
#   2. gcloud projects add-iam-policy-binding tripbot-prod \
#        --member serviceAccount:terraform@tripbot-prod.iam.gserviceaccount.com \
#        --role roles/serviceusage.serviceUsageAdmin
#   3. gcloud iam service-accounts keys create key.json \
#        --iam-account terraform@tripbot-prod.iam.gserviceaccount.com
#   4. aws-vault exec adanalife-prod -- aws secretsmanager put-secret-value \
#        --secret-id prod-1/gcp-terraform-credentials --secret-string "$(cat key.json)"
resource "aws_secretsmanager_secret" "gcp_terraform_credentials" {
  name        = "prod-1/gcp-terraform-credentials"
  description = "GCP service-account JSON key used by the google terraform provider. Role: serviceusage.serviceUsageAdmin on tripbot-prod."
}

resource "aws_secretsmanager_secret_version" "gcp_terraform_credentials" {
  secret_id     = aws_secretsmanager_secret.gcp_terraform_credentials.id
  secret_string = "placeholder — set via aws secretsmanager put-secret-value"
  lifecycle {
    ignore_changes = [secret_string]
  }
}

data "aws_secretsmanager_secret_version" "gcp_terraform_credentials" {
  secret_id = aws_secretsmanager_secret.gcp_terraform_credentials.id
}

# ============================================================================
# Google Maps
# ============================================================================

# Google Maps API key for prod-1 tripbot. Separate key from stage-1's (same
# GCP project, distinct API keys) so a leak in one env doesn't compromise the
# other. Restricted to the Geocoding + Maps JavaScript APIs.
# See vault/tripbot/credentials.md for minting / rotation.
#
# Bootstrap:
#   aws-vault exec adanalife-prod -- aws secretsmanager put-secret-value \
#     --secret-id k8s/tripbot/google-maps-api-key \
#     --secret-string '{"GOOGLE_MAPS_API_KEY":"AIza..."}'
resource "aws_secretsmanager_secret" "tripbot_google_maps_api_key" {
  name        = "k8s/tripbot/google-maps-api-key"
  description = "Google Maps API key for tripbot (prod-1). Key holds GOOGLE_MAPS_API_KEY. Consumed by pkg/chatbot (!location) and pkg/video. Restricted to Geocoding + Maps JavaScript APIs."
}

resource "aws_secretsmanager_secret_version" "tripbot_google_maps_api_key" {
  secret_id     = aws_secretsmanager_secret.tripbot_google_maps_api_key.id
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
# Discord alerts webhook — SHARED VALUE with the stage account
# ============================================================================
#
# The same Discord webhook URL is stored in BOTH AWS accounts under the same SM
# name (k8s/tripbot/discord-alerts-webhook) because the consumers live in
# different accounts and can't cross-read:
#   - prod (this file) — consumed at runtime by tripbot's reportCmd via the
#     tripbot-discord-alerts-webhook ExternalSecret in k8s/apps/tripbot/base/.
#   - stage (stage-1/secrets.tf) — same SM name, consumed by both that
#     ExternalSecret (tripbot !report) AND grafana_contact_point in
#     grafana-alerts.tf (terraform-side infra alerts).
#
# Populate BOTH with the same URL after `task tf:{stage,prod}:apply`:
#   aws-vault exec adanalife-stage -- aws secretsmanager put-secret-value \
#     --secret-id k8s/tripbot/discord-alerts-webhook --secret-string '<URL>'
#   aws-vault exec adanalife-prod  -- aws secretsmanager put-secret-value \
#     --secret-id k8s/tripbot/discord-alerts-webhook --secret-string '<URL>'
resource "aws_secretsmanager_secret" "discord_alerts_webhook" {
  name        = "k8s/tripbot/discord-alerts-webhook"
  description = "Discord webhook for tripbot reportCmd. Same value as k8s/tripbot/discord-alerts-webhook in adanalife-stage."
}

resource "aws_secretsmanager_secret_version" "discord_alerts_webhook" {
  secret_id     = aws_secretsmanager_secret.discord_alerts_webhook.id
  secret_string = "placeholder — set via aws secretsmanager put-secret-value"
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Discord bot token for the production tripbot Discord session (pkg/discord).
# Consumed at runtime via the tripbot-discord-bot-token ExternalSecret in
# k8s/apps/tripbot/base/. pkg/discord skips startup cleanly while this is
# the placeholder string, so the bot stays gated off after this resource
# lands and only flips on after `aws secretsmanager put-secret-value` and
# setting DISCORD_GUILD_ID in the prod ConfigMap.
resource "aws_secretsmanager_secret" "tripbot_discord_bot_token" {
  name        = "k8s/tripbot/discord-bot-token"
  description = "Discord bot token for the production tripbot Discord session."
}

resource "aws_secretsmanager_secret_version" "tripbot_discord_bot_token" {
  secret_id     = aws_secretsmanager_secret.tripbot_discord_bot_token.id
  secret_string = "placeholder — set via aws secretsmanager put-secret-value"
  lifecycle {
    ignore_changes = [secret_string]
  }
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
      aws_secretsmanager_secret.tripbot_google_maps_api_key.arn,
      # prod-only — GCP terraform-provider credential (defined above; google.tf
      # reads it via data source on every plan). Stage-1 has no GCP, so this is
      # an intended divergence from the KEEP-IN-SYNC sibling, same as argocd below.
      aws_secretsmanager_secret.gcp_terraform_credentials.arn,
      aws_secretsmanager_secret.tripbot_db_credentials.arn,
      aws_secretsmanager_secret.postgres_backup_s3.arn,
      aws_secretsmanager_secret.discord_alerts_webhook.arn,
      aws_secretsmanager_secret.tripbot_discord_bot_token.arn,
      # prod-only — Argo CD repo deploy key (defined in argocd.tf, which exists
      # only in prod-1). Folded into this bulk read grant rather than a standalone
      # policy because CITerraformRole is at AWS's hard cap of 10 managed policies
      # per role; this is a read grant with the same actions as the rest of the
      # list, so it's a natural fit. This is the one intended divergence from the
      # KEEP-IN-SYNC sibling stage-1/secrets.tf (stage has no Argo CD).
      aws_secretsmanager_secret.argocd_repo_ssh_key.arn,
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

# ============================================================================
# Postgres credentials (k8s/postgres/credentials)
# ============================================================================
#
# Credentials for tripbot's Postgres on adanalife-minipc. Unlike other
# SM containers here, terraform OWNS the value: random_pet generates a
# passphrase-style password, jsonencode wraps it with the user/db
# fields, and `aws_secretsmanager_secret_version` writes the result.
# ESO in-cluster materializes this into the `postgres-secret` Secret
# via the ExternalSecret at k8s/apps/postgres/overlays/prod-1/.
#
# No `lifecycle { ignore_changes = [secret_string] }` here — that
# would defeat the point of letting terraform manage the value.
# random_pet is deterministic given the same seed/keepers, so the
# password is stable across applies unless `keepers` changes.
#
# Password rotation: set/bump `keepers.rotation_id` on random_pet, then
# `terraform apply`. After SM updates, ESO syncs (≤1h or force) and
# then `kubectl exec postgres-0 -- psql -c "ALTER USER tripbot WITH
# PASSWORD '<new-from-SM>';"` to bring pg_authid in line.

resource "random_pet" "tripbot_db_password" {
  length    = 4
  separator = "-"
}

resource "aws_secretsmanager_secret" "tripbot_db_credentials" {
  name        = "k8s/postgres/credentials"
  description = "Postgres credentials for tripbot on adanalife-minipc."
}

resource "aws_secretsmanager_secret_version" "tripbot_db_credentials" {
  secret_id = aws_secretsmanager_secret.tripbot_db_credentials.id
  secret_string = jsonencode({
    user     = "tripbot"
    password = random_pet.tripbot_db_password.id
    db       = "tripbot"
  })
}

# CI lifecycle grant — same shape as the other ci_terraform_*_manage
# blocks, but with PutSecretValue added because terraform writes the
# value (not an out-of-band aws-cli put).
data "aws_iam_policy_document" "ci_terraform_postgres_credentials_manage" {
  statement {
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
      "secretsmanager:UpdateSecret",
      "secretsmanager:PutSecretValue",
    ]
    resources = [
      "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:k8s/postgres/credentials-*",
    ]
  }
}

resource "aws_iam_policy" "ci_terraform_postgres_credentials_manage" {
  name        = "AllowCITerraformManageProd1PostgresCredentials"
  description = "Lifecycle access for CITerraformRole to the k8s/postgres/credentials SM secret in prod-1, including PutSecretValue (terraform owns the value)."
  policy      = data.aws_iam_policy_document.ci_terraform_postgres_credentials_manage.json
}

resource "aws_iam_role_policy_attachment" "ci_terraform_postgres_credentials_manage" {
  role       = aws_iam_role.ci_terraform.name
  policy_arn = aws_iam_policy.ci_terraform_postgres_credentials_manage.arn
}

# k8s/postgres/backup-s3-credentials — PutSecretValue included because
# terraform writes the value (IAM access key id + secret + bucket + region).
# Resource definition lives in postgres-backup.tf.
data "aws_iam_policy_document" "ci_terraform_postgres_backup_s3_manage" {
  statement {
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
      "secretsmanager:UpdateSecret",
      "secretsmanager:PutSecretValue",
    ]
    resources = [
      "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:k8s/postgres/backup-s3-credentials-*",
    ]
  }
}

resource "aws_iam_policy" "ci_terraform_postgres_backup_s3_manage" {
  name        = "AllowCITerraformManageProd1PostgresBackupS3"
  description = "Lifecycle access for CITerraformRole to the k8s/postgres/backup-s3-credentials SM secret in prod-1, including PutSecretValue (terraform owns the value)."
  policy      = data.aws_iam_policy_document.ci_terraform_postgres_backup_s3_manage.json
}

resource "aws_iam_role_policy_attachment" "ci_terraform_postgres_backup_s3_manage" {
  role       = aws_iam_role.ci_terraform.name
  policy_arn = aws_iam_policy.ci_terraform_postgres_backup_s3_manage.arn
}
