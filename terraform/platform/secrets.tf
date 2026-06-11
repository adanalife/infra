# AWS Secrets Manager — platform SM containers + CI grants (core account).
#
# Same shape as stage-1/secrets.tf: this file is the single bookkeeping point
# for "what SM containers exist in this workspace."
#
# Per-secret pattern (from vault/decisions/secrets-manager-for-tf-providers.md):
#   - `aws_secretsmanager_secret`     — container, terraform-managed.
#   - `aws_secretsmanager_secret_version` with `lifecycle.ignore_changes =
#     [secret_string]` so the placeholder doesn't clobber out-of-band updates.
#   - `data.aws_secretsmanager_secret_version` when terraform itself needs
#     the value at plan time (e.g. provider auth).
#
# First-apply flow (chicken-and-egg with the github provider) — full runbook
# in vault/infra/github-app-automation.md:
#   1. `task tf:platform:apply -- -target=aws_secretsmanager_secret_version.github_automation_app_key`
#   2. aws-vault exec adanalife-core -- aws secretsmanager put-secret-value \
#        --secret-id platform/github-automation-app-private-key \
#        --secret-string "$(cat adanalife-automation.*.private-key.pem)"
#   3. `task tf:platform:apply` — the github provider auths cleanly.

# ============================================================================
# GitHub automation App
# ============================================================================

resource "aws_secretsmanager_secret" "github_automation_app_key" {
  name        = "platform/github-automation-app-private-key"
  description = "Private key (PEM) for the adanalife-automation GitHub App. Read by the github terraform provider (app_auth) and fanned out to repo Actions secrets so workflows can mint installation tokens."
}

resource "aws_secretsmanager_secret_version" "github_automation_app_key" {
  secret_id     = aws_secretsmanager_secret.github_automation_app_key.id
  secret_string = "placeholder — set via aws secretsmanager put-secret-value"
  lifecycle {
    ignore_changes = [secret_string]
  }
}

data "aws_secretsmanager_secret_version" "github_automation_app_key" {
  secret_id = aws_secretsmanager_secret.github_automation_app_key.id
}

# ============================================================================
# CI read grant — GetSecretValue for the SM containers terraform refreshes
# during plan. Scoped to specific ARNs so CI can't read other secrets in the
# core account. The role itself is declared in core's state (ci.tf); platform
# only attaches to it.
# ============================================================================

data "aws_iam_role" "ci_terraform" {
  name = "CITerraformRole"
}

data "aws_iam_policy_document" "ci_terraform_secrets_read" {
  statement {
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecretVersionIds",
    ]
    resources = [
      aws_secretsmanager_secret.github_automation_app_key.arn,
    ]
  }
}

resource "aws_iam_policy" "ci_terraform_secrets_read" {
  name        = "AllowCITerraformReadPlatformSecrets"
  description = "Read-only access for CITerraformRole to the SM secrets terraform refreshes during plan in the platform workspace."
  policy      = data.aws_iam_policy_document.ci_terraform_secrets_read.json
}

resource "aws_iam_role_policy_attachment" "ci_terraform_secrets_read" {
  role       = data.aws_iam_role.ci_terraform.name
  policy_arn = aws_iam_policy.ci_terraform_secrets_read.arn
}
