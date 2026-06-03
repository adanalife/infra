# AWS Secrets Manager — stage-1 SM containers + CI lifecycle grants.
#
# As of 2026-05-11 consolidation: this file is the single bookkeeping point
# for "what SM containers exist in this AWS account." Topic files
# (grafana-cloud.tf, grafana-k8s-monitoring.tf, etc.) keep their consumer-
# side resources (IAM users, providers, locals, dashboards) but no longer
# declare SM containers themselves.
#
# Per-secret pattern (from vault/decisions/secrets-manager-for-tf-providers.md):
#   - `aws_secretsmanager_secret`     — container, terraform-managed.
#   - `aws_secretsmanager_secret_version` with `lifecycle.ignore_changes =
#     [secret_string]` so the placeholder doesn't clobber out-of-band updates.
#   - Optional `data.aws_secretsmanager_secret_version` if terraform itself
#     needs the value at plan time (e.g. provider auth).
#   - Container only (no version resource) if the secret should never be
#     refreshed by CI — e.g. stream keys, where CI compromise should not give
#     read access. Value seeded out-of-band, read at runtime by ESO.
#
# CI lifecycle grants live at the bottom of this file:
#   - `ci_terraform_secrets_read`: bulk GetSecretValue for SM containers
#     terraform refreshes during plan (any with a version resource or data
#     source).
#   - Per-secret lifecycle policies (CreateSecret / DeleteSecret / Update /
#     Tag) for k8s/* SM containers that CI manages the container of. No
#     GetSecretValue; the value is admin-owned (out-of-band put-secret-value)
#     and ESO-readable.
#
# First-apply flow (chicken-and-egg with the cloudflare provider):
#   1. `task tf:stage:apply` — SM resources apply; cloudflare_* resources
#      fail on the placeholder token (expected).
#   2. Populate the cloudflare-api-token + any other secrets needed for
#      provider auth or at-plan reads. Examples:
#        aws-vault exec adanalife-stage -- aws secretsmanager put-secret-value \
#          --secret-id stage-1/cloudflare-api-token --secret-string "$CLOUDFLARE_API_TOKEN"
#   3. `task tf:stage:apply` again — provider auths cleanly.

# ============================================================================
# Cloudflare
# ============================================================================

resource "aws_secretsmanager_secret" "cloudflare_api_token" {
  name        = "stage-1/cloudflare-api-token"
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

# OTLP credentials for in-cluster OpenTelemetry exporters (tripbot, vlc-server).
# Bootstrap:
#   aws-vault exec adanalife-stage -- aws secretsmanager put-secret-value \
#     --secret-id k8s/grafana-cloud-otlp \
#     --secret-string '{"OTEL_EXPORTER_OTLP_ENDPOINT":"https://otlp-gateway-prod-us-central-0.grafana.net/otlp","OTEL_EXPORTER_OTLP_HEADERS":"Authorization=Basic <base64(instanceID:apiKey)>"}'
# ESO picks up new values within an hour; force-sync with
#   kubectl annotate externalsecret grafana-cloud-otlp force-sync=$(date +%s) --overwrite
# The k8s/ name prefix matches AllowESOReadK8sSecrets in eso.tf, so ESO can read
# without extra IAM grants.
resource "aws_secretsmanager_secret" "grafana_cloud_otlp" {
  name        = "k8s/grafana-cloud-otlp"
  description = "Grafana Cloud OTLP endpoint + bearer auth for in-cluster OTel exporters."
}

resource "aws_secretsmanager_secret_version" "grafana_cloud_otlp" {
  secret_id     = aws_secretsmanager_secret.grafana_cloud_otlp.id
  secret_string = jsonencode({ placeholder = "set via aws secretsmanager put-secret-value" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Grafana Cloud admin API credentials consumed terraform-side by the `grafana`
# provider (see grafana.tf). Seeded via:
#   aws-vault exec adanalife-stage -- aws secretsmanager put-secret-value \
#     --secret-id stage-1/grafana-cloud-api \
#     --secret-string '{"GRAFANA_CLOUD_URL":"https://<stack>.grafana.net","GRAFANA_CLOUD_API_TOKEN":"<token>","GRAFANA_CLOUD_STACK_SLUG":"<stack>"}'
# Token: mint a service account in the stack with Admin role, then create a
# token under it. Stack slug = the subdomain of your URL. Lives at stage-1/*
# (terraform-only consumer) so it stays out of the ESOSecretsReader scope.
resource "aws_secretsmanager_secret" "grafana_cloud_api" {
  name        = "stage-1/grafana-cloud-api"
  description = "Grafana Cloud admin API token + stack URL/slug for the grafana terraform provider."
}

resource "aws_secretsmanager_secret_version" "grafana_cloud_api" {
  secret_id     = aws_secretsmanager_secret.grafana_cloud_api.id
  secret_string = jsonencode({ placeholder = "set via aws secretsmanager put-secret-value" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

data "aws_secretsmanager_secret_version" "grafana_cloud_api" {
  secret_id  = aws_secretsmanager_secret.grafana_cloud_api.id
  depends_on = [aws_secretsmanager_secret_version.grafana_cloud_api] # cold-start ordering
}

# Metrics + logs write credentials for the in-cluster grafana-k8s-monitoring
# helm chart (Alloy + kube-state-metrics + node-exporter + cAdvisor). Separate
# token from grafana_cloud_otlp so the cluster-monitoring blast radius is
# isolated from the app-side OTel exporters.
#
# Container only (no version resource) — value populated out-of-band and
# consumed by Alloy at runtime via ESO. Same precedent as k8s_obs_twitch_stream_key:
# no GetSecretValue grant for CITerraformRole, and a CI compromise can't read
# the token out of state.
#
# Bootstrap (after first `task tf:stage:apply`):
#   aws-vault exec adanalife-stage -- aws secretsmanager put-secret-value \
#     --secret-id k8s/grafana-cloud-metrics-write \
#     --secret-string '{
#       "PROMETHEUS_HOST": "https://prometheus-prod-XX-XXX.grafana.net",
#       "PROMETHEUS_USERNAME": "<numeric prom instance ID>",
#       "LOKI_HOST": "https://logs-prod-XXX.grafana.net",
#       "LOKI_USERNAME": "<numeric loki instance ID>",
#       "TOKEN": "<Grafana Cloud Access Policy token with metrics:write + logs:write>"
#     }'
# Endpoints + numeric IDs come from Grafana Cloud `Connections → Add new
# connection → Hosted Prometheus / Hosted Loki`. Token via Grafana Cloud admin
# → Access Policies with scopes `metrics:write` + `logs:write`.
resource "aws_secretsmanager_secret" "k8s_grafana_cloud_metrics_write" {
  name        = "k8s/grafana-cloud-metrics-write"
  description = "Grafana Cloud Mimir/Loki credentials for the in-cluster k8s-monitoring chart. Consumed by Alloy via ESO."

  # CI-driven applies need the lifecycle policy attached to CITerraformRole
  # before AWS will accept CreateSecret on this ARN. Local applies (admin role)
  # don't care, but the explicit ordering is required for a CI bootstrap to
  # succeed without a retry.
  depends_on = [aws_iam_role_policy_attachment.ci_terraform_grafana_metrics_write_manage]
}

# ============================================================================
# Sentry
# ============================================================================

# Sentry DSNs for the tripbot bot and vlc-server services. Two SM secrets, one
# per Sentry project. Both materialize into k8s Secrets via ExternalSecret
# resources owned by each app's overlay (k8s/apps/*), envFrom'd into the
# respective Deployments as SENTRY_DSN.
#
# Bootstrap:
#   aws-vault exec adanalife-stage -- aws secretsmanager put-secret-value \
#     --secret-id k8s/sentry-tripbot \
#     --secret-string '{"SENTRY_DSN":"https://<key>@<org>.ingest.sentry.io/<project>"}'
# and again for k8s/sentry-vlc-server with the matching DSN.
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

# Twitch app credentials (Helix API + OAuth Authorization Code flow) for the
# tripbot Go service. One SM secret holding TWITCH_CLIENT_ID + TWITCH_CLIENT_SECRET.
# The IRC token is no longer here — since tripbot v2.3.0 it lives in the
# oauth_tokens DB table, populated by `task auth:bootstrap` and rotated hourly.
#
# Materializes into a k8s Secret via an ExternalSecret resource owned by
# k8s/apps/tripbot/overlays/local/, envFrom'd into the Deployment.
#
# Bootstrap:
#   aws-vault exec adanalife-stage -- aws secretsmanager put-secret-value \
#     --secret-id k8s/tripbot/twitch-creds \
#     --secret-string '{"TWITCH_CLIENT_ID":"...","TWITCH_CLIENT_SECRET":"..."}'
resource "aws_secretsmanager_secret" "tripbot_twitch_creds" {
  name        = "k8s/tripbot/twitch-creds"
  description = "Twitch app credentials for tripbot. App: tripbot-development. Keys: TWITCH_CLIENT_ID, TWITCH_CLIENT_SECRET. Consumed by pkg/twitch (Helix API + OAuth Authorization Code flow). IRC token lives in the oauth_tokens DB table, not in this secret."
}

resource "aws_secretsmanager_secret_version" "tripbot_twitch_creds" {
  secret_id     = aws_secretsmanager_secret.tripbot_twitch_creds.id
  secret_string = jsonencode({ placeholder = "set via aws secretsmanager put-secret-value" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ============================================================================
# Google Maps
# ============================================================================

# Google Maps API key for the tripbot Go service. Used by the `!location`
# chat command (`pkg/chatbot/commands.go` → `helpers.CityFromCoords`) and
# during video ingest (`pkg/video/db.go` → `helpers.StateFromCoords`); the
# tripbot config marks it `required:"true"`, so the bot won't boot without
# it. Per-env keys (stage and prod are separate API keys in the same GCP
# project, restricted to the Geocoding + Maps JavaScript APIs) for bounded
# blast radius. See vault/tripbot/credentials.md for minting / rotation.
#
# Materializes into a k8s Secret via an ExternalSecret resource owned by
# k8s/apps/tripbot/overlays/local/, envFrom'd into the Deployment.
#
# Bootstrap:
#   aws-vault exec adanalife-stage -- aws secretsmanager put-secret-value \
#     --secret-id k8s/tripbot/google-maps-api-key \
#     --secret-string '{"GOOGLE_MAPS_API_KEY":"AIza..."}'
resource "aws_secretsmanager_secret" "tripbot_google_maps_api_key" {
  name        = "k8s/tripbot/google-maps-api-key"
  description = "Google Maps API key for tripbot. Key holds GOOGLE_MAPS_API_KEY. Consumed by pkg/chatbot (!location command) and pkg/video (state lookup on ingest). Restricted to Geocoding + Maps JavaScript APIs. Stage and prod are distinct keys."
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

# Twitch RTMP ingest key for the adanalife_staging channel. No terraform-side
# consumer (no data source); ESO reads it at runtime once the platform stack
# lands. The k8s/obs/ name prefix puts this inside the ESOSecretsReader read
# scope (k8s/*); CI lifecycle is granted narrowly per-secret below.
# Populate out-of-band (terraform-via-CI never sees the value):
#   aws-vault exec adanalife-stage -- aws secretsmanager put-secret-value \
#     --secret-id k8s/obs/twitch-stream-key --secret-string "$STREAM_KEY"
# Get the key from https://dashboard.twitch.tv/u/adanalife_staging/settings/stream
# Container only — terraform deliberately doesn't manage the version resource.
# Keeping the version out of terraform state means CI never refreshes it (no
# GetSecretValue grant required) and a CITerraformRole compromise can't read
# the stream key.
resource "aws_secretsmanager_secret" "k8s_obs_twitch_stream_key" {
  name        = "k8s/obs/twitch-stream-key"
  description = "Twitch RTMP stream key for adanalife_staging. Consumed by OBS via ESO. Rotate from the Twitch dashboard, then put-secret-value here."

  # CI-driven applies need the lifecycle policy attached to CITerraformRole
  # before AWS will accept CreateSecret on this ARN. Local applies (admin role)
  # don't care, but the explicit ordering is required for a CI bootstrap to
  # succeed without a retry.
  depends_on = [aws_iam_role_policy_attachment.ci_terraform_twitch_stream_key_manage]
}

# ============================================================================
# Discord alerts webhook
# ============================================================================
#
# One webhook URL, one SM container, two consumers in this account:
#   - Grafana Cloud contact point (grafana-alerts.tf, terraform-side) — routes
#     infra monitoring alerts to Discord. Reads the value at plan via the data
#     source below.
#   - tripbot's !report command (pkg/chatbot reportCmd) — posts viewer reports
#     to Discord at runtime, via the tripbot-discord-alerts-webhook ExternalSecret
#     in k8s/apps/tripbot/base/ (shared across all envs).
#
# Named under k8s/* so in-cluster ESO can read it (ESO's read scope is k8s/*);
# terraform reads it too via the ci_terraform_secrets_read grant below. The same
# value also lives at k8s/tripbot/discord-alerts-webhook in adanalife-prod
# (prod-1/secrets.tf) — separate account, can't cross-read.
#
# Populate after `task tf:stage:apply`:
#   aws-vault exec adanalife-stage -- aws secretsmanager put-secret-value \
#     --secret-id k8s/tripbot/discord-alerts-webhook --secret-string '<URL>'
resource "aws_secretsmanager_secret" "discord_alerts_webhook" {
  name        = "k8s/tripbot/discord-alerts-webhook"
  description = "Discord webhook for infra alerts (Grafana contact point) and tripbot's !report command. Same value as k8s/tripbot/discord-alerts-webhook in adanalife-prod."
}

resource "aws_secretsmanager_secret_version" "discord_alerts_webhook" {
  secret_id     = aws_secretsmanager_secret.discord_alerts_webhook.id
  secret_string = "placeholder — set via aws secretsmanager put-secret-value"
  lifecycle {
    ignore_changes = [secret_string]
  }
}

data "aws_secretsmanager_secret_version" "discord_alerts_webhook" {
  secret_id  = aws_secretsmanager_secret.discord_alerts_webhook.id
  depends_on = [aws_secretsmanager_secret_version.discord_alerts_webhook]
}

# Discord bot token for the staging tripbot Discord session (pkg/discord).
# Consumed at runtime via the tripbot-discord-bot-token ExternalSecret in
# k8s/apps/tripbot/base/; pkg/discord skips startup cleanly when this is
# still the placeholder string, so leaving it unpopulated keeps the bot
# gated off without blocking apply.
resource "aws_secretsmanager_secret" "tripbot_discord_bot_token" {
  name        = "k8s/tripbot/discord-bot-token"
  description = "Discord bot token for the staging tripbot Discord session."
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

# Allow CITerraformRole to read the SM secrets that terraform itself touches
# at plan time. ReadOnlyAccess (already attached) excludes
# secretsmanager:GetSecretValue. Two distinct call sites need it:
#   - provider data sources (cloudflare provider reads its own token at plan
#     via `data.aws_secretsmanager_secret_version.cloudflare_api_token`);
#   - `aws_secretsmanager_secret_version` resource refresh, which calls
#     GetSecretValue to compare current value against state — even with
#     `ignore_changes = [secret_string]`, the refresh still reads.
# Scoped to specific ARNs so CI can't read the values of other secrets in
# the account.
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
      aws_secretsmanager_secret.tripbot_db_credentials.arn,
      aws_secretsmanager_secret.discord_alerts_webhook.arn,
      aws_secretsmanager_secret.tripbot_discord_bot_token.arn,
    ]
  }
}

resource "aws_iam_policy" "ci_terraform_secrets_read" {
  name        = "AllowCITerraformReadStage1Secrets"
  description = "Read-only access for CITerraformRole to the SM secrets terraform refreshes during plan in stage-1."
  policy      = data.aws_iam_policy_document.ci_terraform_secrets_read.json
}

resource "aws_iam_role_policy_attachment" "ci_terraform_secrets_read" {
  role       = aws_iam_role.ci_terraform.name
  policy_arn = aws_iam_policy.ci_terraform_secrets_read.arn
}

# --- Per-secret lifecycle grants ---
#
# Each k8s/* SM secret that needs CI-applicable lifecycle (CreateSecret /
# DeleteSecret / UpdateSecret / Tag) but should NOT be CI-readable gets its
# own narrow policy. The `-*` ARN suffix handles AWS's auto-appended 6-char
# random ID, which the CreateSecret IAM check evaluates against the to-be-
# created ARN.

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
  name        = "AllowCITerraformManageStage1TwitchStreamKey"
  description = "Lifecycle access for CITerraformRole to the k8s/obs/twitch-stream-key SM secret in stage-1 (container only — value stays placeholder via ignore_changes)."
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
  name        = "AllowCITerraformManageStage1GrafanaMetricsWrite"
  description = "Lifecycle access for CITerraformRole to the k8s/grafana-cloud-metrics-write SM secret in stage-1 (container only — value stays out-of-terraform)."
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
# Credentials for tripbot's Postgres in the stage-1 environment on
# adanalife-minipc. Mirrors terraform/prod-1/secrets.tf: terraform OWNS
# the value — random_pet generates a passphrase-style password, jsonencode
# wraps it with the user/db fields, and aws_secretsmanager_secret_version
# writes the result. ESO (the aws-secretsmanager-stage ClusterSecretStore)
# materializes it into the `postgres-secret` Secret in the stage-1
# namespace via the ExternalSecret at k8s/apps/postgres/overlays/stage-1/.
#
# stage-1's Postgres is fresh-seeded and disposable, but the credential
# still flows through SM/ESO (not committed literals) to stay symmetric
# with prod and keep secrets out of git.
#
# Password rotation: bump keepers.rotation_id on random_pet, then apply;
# after SM updates, ESO syncs (≤1h or force) and then ALTER USER to bring
# pg_authid in line.

resource "random_pet" "tripbot_db_password" {
  length    = 4
  separator = "-"
}

resource "aws_secretsmanager_secret" "tripbot_db_credentials" {
  name        = "k8s/postgres/credentials"
  description = "Postgres credentials for tripbot in stage-1 on adanalife-minipc."
}

resource "aws_secretsmanager_secret_version" "tripbot_db_credentials" {
  secret_id = aws_secretsmanager_secret.tripbot_db_credentials.id
  secret_string = jsonencode({
    user     = "tripbot"
    password = random_pet.tripbot_db_password.id
    db       = "tripbot"
  })
}

# CI lifecycle grant — includes PutSecretValue because terraform writes the
# value (not an out-of-band aws-cli put). The container ARN is also in the
# ci_terraform_secrets_read list above, since terraform refreshes the
# version during plan.
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
  name        = "AllowCITerraformManageStage1PostgresCredentials"
  description = "Lifecycle access for CITerraformRole to the k8s/postgres/credentials SM secret in stage-1, including PutSecretValue (terraform owns the value)."
  policy      = data.aws_iam_policy_document.ci_terraform_postgres_credentials_manage.json
}

resource "aws_iam_role_policy_attachment" "ci_terraform_postgres_credentials_manage" {
  role       = aws_iam_role.ci_terraform.name
  policy_arn = aws_iam_policy.ci_terraform_postgres_credentials_manage.arn
}
