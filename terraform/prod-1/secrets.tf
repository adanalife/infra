# SSM Parameter Store — prod-1 parameters + CI grants.
# KEEP-IN-SYNC: terraform/stage-1/secrets.tf (same shape; env-specific
# entries differ — see each file's map. Prod-only parameters that belong to
# topic files stay there: argocd.tf, tailscale.tf, postgres-backup.tf.)
#
# Migrated from AWS Secrets Manager 2026-07 (SM bills $0.40/secret/month;
# standard-tier parameters are free). The SM containers, their version
# resources, and the per-secret SM CI grants were deleted in the migration's
# final phase; live values were copied by bin/migrate-sm-to-ssm.sh and the
# full pre-migration corpus is archived offline (encrypted, 2026-07-03).
#
# See stage-1/secrets.tf's header for the per-parameter pattern, seeding
# syntax, and the fresh-account first-apply flow. Short version:
#   aws-vault exec adanalife-prod -- aws ssm put-parameter \
#     --name /<path> --type SecureString --overwrite --value '<value>'

# ============================================================================
# Parameters (out-of-band values)
# ============================================================================
#
# Seeding notes (shapes match stage — see stage-1/secrets.tf):
#   - k8s/tripbot/twitch-creds — prod app (not tripbot-development).
#   - k8s/tripbot/discord-alerts-webhook — same value as the stage account's.
#   - k8s/arc/github-app — JSON {"github_app_id": ..., "github_app_installation_id": ...,
#     "github_app_private_key": ...} for the runner scale set.

locals {
  # parameter name (sans leading /) => description
  ssm_parameters = {
    "prod-1/cloudflare-api-token"          = "Cloudflare API token used by the cloudflare provider."
    "prod-1/grafana-cloud-api"             = "Grafana Cloud admin API token + stack URL/slug for the grafana terraform provider."
    "k8s/grafana-cloud-otlp"               = "Grafana Cloud OTLP endpoint + bearer auth for in-cluster OTel exporters."
    "k8s/sentry-tripbot"                   = "Sentry DSN for the tripbot Go service. Consumed via the SENTRY_DSN env var."
    "k8s/sentry-vlc-server"                = "Sentry DSN for the vlc-server Go service. Consumed via the SENTRY_DSN env var."
    "k8s/sentry-onscreens-server"          = "Sentry DSN for the onscreens-server Go service. Consumed via the SENTRY_DSN env var."
    "k8s/sentry-platform-gateway"          = "Sentry DSN for the platform-gateway service. Consumed via the SENTRY_DSN env var."
    "k8s/sentry-tripbot-console"           = "Sentry DSN for the tripbot-console service. Consumed via the SENTRY_DSN env var."
    "k8s/sentry-video-pipeline"            = "Sentry DSN for the video-pipeline batch jobs. Consumed via the SENTRY_DSN env var."
    "k8s/tripbot/twitch-creds"             = "Twitch app credentials for tripbot. Keys: TWITCH_CLIENT_ID, TWITCH_CLIENT_SECRET."
    "k8s/tripbot/google-maps-api-key"      = "Google Maps API key for tripbot. Key holds GOOGLE_MAPS_API_KEY."
    "k8s/tripbot/youtube-creds"            = "YouTube OAuth client credentials for tripbot. Keys: YOUTUBE_CLIENT_ID, YOUTUBE_CLIENT_SECRET, optionally YOUTUBE_CHANNEL_ID."
    "k8s/tripbot/discord-alerts-webhook"   = "Discord webhook for infra alerts (Grafana contact point) and tripbot's !report command."
    "k8s/tripbot/discord-bot-token"        = "Discord bot token for the prod tripbot Discord session."
    "k8s/tripbot-console/ghcr-pull-token"  = "GitHub token (read:packages) for pulling the private tripbot-console image from GHCR. Keys: username, token."
    "k8s/platform-gateway/ghcr-pull-token" = "GitHub token (read:packages) for pulling the private platform-gateway image from GHCR. Keys: username, token."
    "k8s/video-pipeline/ghcr-pull-token"   = "GitHub token (read:packages) for pulling the private video-pipeline image from GHCR. Keys: username, token."
    "k8s/arc/github-app"                   = "GitHub App credentials for the self-hosted runner controller (ARC). Keys: github_app_id, github_app_installation_id, github_app_private_key."
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

# k8s/postgres/credentials — terraform OWNS the value: random_pet generates a
# passphrase-style password, jsonencode wraps it with the user/db fields. ESO
# materializes it into the `postgres-secret` Secret in the prod-1-data
# namespace via the ExternalSecret in the data unit.
#
# No `ignore_changes` — that would defeat letting terraform manage the value.
# random_pet is deterministic given the same keepers, so the password is
# stable across applies unless `keepers` changes.
#
# Password rotation: set/bump `keepers.rotation_id` on random_pet, then
# apply. After the parameter updates, ESO syncs (≤1h or force) and then
# `kubectl exec postgres-0 -- psql -c "ALTER USER tripbot WITH PASSWORD
# '<new>';"` to bring pg_authid in line.

resource "random_pet" "tripbot_db_password" {
  length    = 4
  separator = "-"
}

resource "aws_ssm_parameter" "tripbot_db_credentials" {
  name        = "/k8s/postgres/credentials"
  description = "Postgres credentials for tripbot on adanalife-minipc."
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
# Same rationale + seeding shapes as stage-1/secrets.tf (a managed parameter
# is CI-readable at refresh; the Deny below keeps CI out):
#   - /k8s/obs/twitch-stream-key   (Twitch dashboard → Stream, prod channel)
#   - /k8s/obs/youtube-stream-key  (YouTube Studio, prod channel)
#   - /k8s/grafana-cloud-metrics-write
#   - /k8s/external-dns/aws-credentials (hand-seeded from PGP outputs)

# ============================================================================
# Plan-time data sources
# ============================================================================

data "aws_ssm_parameter" "cloudflare_api_token" {
  name = aws_ssm_parameter.mirror["prod-1/cloudflare-api-token"].name
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
  name        = "AllowCITerraformReadProd1Secrets"
  description = "SSM parameter read + lifecycle for CITerraformRole in prod-1 (read denied on the sensitive unmanaged parameters)."
  policy      = data.aws_iam_policy_document.ci_terraform_secrets_read.json
}

resource "aws_iam_role_policy_attachment" "ci_terraform_secrets_read" {
  role       = aws_iam_role.ci_terraform.name
  policy_arn = aws_iam_policy.ci_terraform_secrets_read.arn
}
