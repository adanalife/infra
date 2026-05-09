# AWS Secrets Manager values for the prod-1 cloudflare provider.
# Mirrors stage-1/secrets.tf. Terraform creates the secret container
# + a placeholder initial version, and `ignore_changes = [secret_string]`
# lets the real value be set out-of-band without terraform clobbering
# it on subsequent applies.
#
# First-apply flow (chicken-and-egg with the cloudflare provider):
#   1. `task tf:prod:apply` — SM resources apply; the cloudflare provider
#      initializes with the placeholder token and every cloudflare_*
#      resource fails. Expected.
#   2. Populate the real value (same token used by stage-1; Pages:Edit
#      scope is account-wide, just stored in a second SM container):
#        aws-vault exec adanalife-prod -- aws secretsmanager put-secret-value \
#          --secret-id prod-1/cloudflare-api-token --secret-string "$CLOUDFLARE_API_TOKEN"
#   3. `task tf:prod:apply` again — cloudflare provider auths, resources apply.

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

# Twitch RTMP ingest key for the adanalife_ (production) channel. No
# terraform-side consumer (no data source); the consumer is a future
# production OBS pod via ESO. The k8s/obs/ name prefix puts this inside
# the ESOSecretsReader read scope (k8s/*); CI lifecycle is granted
# narrowly per-secret via the policy below.
# Populate out-of-band (terraform-via-CI never sees the value):
#   aws-vault exec adanalife-prod -- aws secretsmanager put-secret-value \
#     --secret-id k8s/obs/twitch-stream-key --secret-string "$STREAM_KEY"
# Get the key from https://dashboard.twitch.tv/u/adanalife/settings/stream
# Container only — terraform deliberately doesn't manage the version
# resource. Real values are populated out-of-band via `aws
# secretsmanager put-secret-value` and read at runtime by ESO. Keeping
# the version out of terraform state means CI never refreshes it (no
# GetSecretValue grant required) and a CITerraformRole compromise can't
# read the stream key.
resource "aws_secretsmanager_secret" "k8s_obs_twitch_stream_key" {
  name        = "k8s/obs/twitch-stream-key"
  description = "Twitch RTMP stream key for adanalife (production). Consumed by OBS via ESO. Rotate from the Twitch dashboard, then put-secret-value here."

  # CI-driven applies need the lifecycle policy attached to
  # CITerraformRole before AWS will accept CreateSecret on this ARN.
  # Local applies (admin role) don't care, but the explicit ordering
  # is required for a CI bootstrap to succeed without a retry.
  depends_on = [aws_iam_role_policy_attachment.ci_terraform_twitch_stream_key_manage]
}

# Allow CITerraformRole to read the secret that the cloudflare provider
# needs at plan time. ReadOnlyAccess (already attached) excludes
# secretsmanager:GetSecretValue, which the cloudflare provider's data
# source uses during `terraform plan` / drift in CI. Scoped to the
# specific ARN — CI can't read the values of other secrets in the
# account.
data "aws_iam_policy_document" "ci_terraform_secrets_read" {
  statement {
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecretVersionIds",
    ]
    resources = [
      aws_secretsmanager_secret.cloudflare_api_token.arn,
    ]
  }
}

resource "aws_iam_policy" "ci_terraform_secrets_read" {
  name        = "AllowCITerraformReadProd1Secrets"
  description = "Read-only access for CITerraformRole to the SM secret managed by terraform/prod-1/secrets.tf"
  policy      = data.aws_iam_policy_document.ci_terraform_secrets_read.json
}

resource "aws_iam_role_policy_attachment" "ci_terraform_secrets_read" {
  role       = aws_iam_role.ci_terraform.name
  policy_arn = aws_iam_policy.ci_terraform_secrets_read.arn
}

# Allow CITerraformRole to manage the lifecycle of the twitch-stream-key
# SM container only. Narrow per-secret scope (least privilege): each
# k8s/* SM secret that needs CI-applicable lifecycle gets its own policy.
# The `-*` ARN suffix handles AWS's auto-appended 6-char random ID,
# which the CreateSecret IAM check evaluates against the to-be-created
# ARN.
#
# No GetSecretValue, no PutSecretValue — the value is owned by the
# admin who runs `aws secretsmanager put-secret-value` out of band, and
# read by ESO via ESOSecretsReader. CITerraformRole only manages the
# container (create/delete/update-description/tag).
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
