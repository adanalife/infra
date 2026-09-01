# SSM Parameter Store — platform parameters + CI grants (core account).
#
# Same shape as stage-1/secrets.tf (see its header for the pattern); this file
# is the single bookkeeping point for "what parameters exist in this workspace."
#
# First-apply flow (chicken-and-egg with the github provider):
#   1. `task tf:platform:apply -- -target=aws_ssm_parameter.github_automation_app_key`
#   2. aws-vault exec adanalife-core -- aws ssm put-parameter \
#        --name /platform/github-automation-app-private-key \
#        --type SecureString --overwrite \
#        --value "$(cat adanalife-automation.*.private-key.pem)"
#   3. `task tf:platform:apply` — the github provider auths cleanly.

# ============================================================================
# GitHub automation App
# ============================================================================

resource "aws_ssm_parameter" "github_automation_app_key" {
  name        = "/platform/github-automation-app-private-key"
  description = "Private key (PEM) for the adanalife-automation GitHub App. Read by the github terraform provider (app_auth) and fanned out to repo Actions secrets so workflows can mint installation tokens."
  type        = "SecureString"
  value       = jsonencode({ placeholder = "set via aws ssm put-parameter" })

  lifecycle {
    ignore_changes = [value]
  }
}

data "aws_ssm_parameter" "github_automation_app_key" {
  name = aws_ssm_parameter.github_automation_app_key.name
}

# ============================================================================
# Grafana Cloud (grafana.tf, grafana-alerts.tf, grafana-guessr.tf,
# grafana-synthetic-monitoring.tf)
# ============================================================================
#
# Out-of-band values, placeholder + ignore_changes pattern (see the
# stage-1/secrets.tf header). Seeding notes:
#   - platform/grafana-cloud-api — JSON {"GRAFANA_CLOUD_URL": "https://<stack>.grafana.net",
#     "GRAFANA_CLOUD_API_TOKEN": ..., "GRAFANA_CLOUD_STACK_SLUG": ...}. Mint a
#     stack service account (Admin role) + token; slug = the URL subdomain.
#   - platform/grafana-sm-access — a bare token, not JSON. Synthetic Monitoring
#     authenticates separately from the rest of the Grafana API, so the admin
#     token above cannot reach it: Grafana → Testing & synthetics → Config →
#     Access tokens. The tenant is already installed; generating a token does
#     not re-install it.
#   - platform/cloudflare-d1-read — a bare token. Scope it to D1 read and
#     nothing else. D1 tokens cannot be scoped per-database, so this reaches
#     both tiers' databases; read-only is what bounds it.
#   - platform/discord-alerts-webhook — the Grafana contact-point webhook URL.
#     Same value as /k8s/tripbot/discord-alerts-webhook in the env accounts,
#     which stays there for its ESO consumers (tripbot's !report, guessr).
#   - platform/ntfy-critical-webhook — ntfy webhook URL for the independent
#     critical-alert contact point.
#   - platform/healthchecks-deadman-ping — healthchecks.io ping URL for the
#     alerting deadman switch.

locals {
  # parameter name (sans leading /) => description
  ssm_parameters = {
    "platform/grafana-cloud-api"         = "Grafana Cloud admin API token + stack URL/slug for the grafana terraform provider."
    "platform/grafana-sm-access"         = "Synthetic Monitoring access token for the grafana provider's sm_access_token."
    "platform/cloudflare-d1-read"        = "Cloudflare API token, D1 read only, for the Grafana Infinity datasource over guessr's play data."
    "platform/discord-alerts-webhook"    = "Discord webhook URL for the Grafana discord-alerts contact point."
    "platform/ntfy-critical-webhook"     = "ntfy webhook URL for the Grafana independent critical-alert contact point."
    "platform/healthchecks-deadman-ping" = "healthchecks.io ping URL for the Grafana alerting deadman switch."
  }
}

resource "aws_ssm_parameter" "grafana" {
  for_each = local.ssm_parameters

  name        = "/${each.key}"
  description = each.value
  type        = "SecureString"
  value       = jsonencode({ placeholder = "set via aws ssm put-parameter" })

  lifecycle {
    ignore_changes = [value]
  }
}

# Plan-time data sources. Literal names, not aws_ssm_parameter.grafana[...].name:
# a data source referencing the map resource is deferred to apply time whenever
# ANY entry is added, which leaves the grafana provider with an unknown token at
# plan and the refresh fails. Fresh-workspace bootstrap: create + seed the
# parameters before the first plan that needs them.

data "aws_ssm_parameter" "grafana_cloud_api" {
  name = "/platform/grafana-cloud-api"
}

data "aws_ssm_parameter" "grafana_sm_access" {
  name = "/platform/grafana-sm-access"
}

data "aws_ssm_parameter" "cloudflare_d1_read" {
  name = "/platform/cloudflare-d1-read"
}

data "aws_ssm_parameter" "discord_alerts_webhook" {
  name = "/platform/discord-alerts-webhook"
}

data "aws_ssm_parameter" "ntfy_critical_webhook" {
  name = "/platform/ntfy-critical-webhook"
}

data "aws_ssm_parameter" "healthchecks_deadman_ping" {
  name = "/platform/healthchecks-deadman-ping"
}

# ============================================================================
# CI read grant — ssm:GetParameter for the parameters terraform refreshes
# during plan (managed parameters are read at refresh; the data source reads
# at plan). Scoped to the /platform/ prefix — every parameter this workspace
# owns lives under it, and nothing sensitive-unmanaged does. The role itself
# is declared in core's state (ci.tf); platform only attaches to it.
# ============================================================================

data "aws_iam_role" "ci_terraform" {
  name = "CITerraformRole"
}

data "aws_iam_policy_document" "ci_terraform_secrets_read" {
  statement {
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = [
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/platform/*",
    ]
  }

  # CI applies need parameter lifecycle on the managed parameters, too.
  statement {
    actions = [
      "ssm:PutParameter",
      "ssm:DeleteParameter",
      "ssm:AddTagsToResource",
      "ssm:RemoveTagsFromResource",
      "ssm:ListTagsForResource",
    ]
    resources = [
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/platform/*",
    ]
  }
}

resource "aws_iam_policy" "ci_terraform_secrets_read" {
  name        = "AllowCITerraformReadPlatformSecrets"
  description = "SSM parameter read + lifecycle for CITerraformRole in the platform workspace."
  policy      = data.aws_iam_policy_document.ci_terraform_secrets_read.json
}

resource "aws_iam_role_policy_attachment" "ci_terraform_secrets_read" {
  role       = data.aws_iam_role.ci_terraform.name
  policy_arn = aws_iam_policy.ci_terraform_secrets_read.arn
}
