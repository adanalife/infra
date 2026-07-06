# SSM Parameter Store — platform parameters + CI grants (core account).
#
# Migrated from AWS Secrets Manager 2026-07 — same shape as stage-1/secrets.tf
# (see its header for the pattern); this file is the single bookkeeping point
# for "what parameters exist in this workspace."
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
# CI read grant — ssm:GetParameter for the parameters terraform refreshes
# during plan (managed parameters are read at refresh; the data source reads
# at plan). Scoped to the specific ARN. The role itself is declared in core's
# state (ci.tf); platform only attaches to it.
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
      aws_ssm_parameter.github_automation_app_key.arn,
    ]
  }

  # CI applies need parameter lifecycle on the managed parameter, too.
  statement {
    actions = [
      "ssm:PutParameter",
      "ssm:DeleteParameter",
      "ssm:AddTagsToResource",
      "ssm:RemoveTagsFromResource",
      "ssm:ListTagsForResource",
    ]
    resources = [
      aws_ssm_parameter.github_automation_app_key.arn,
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
