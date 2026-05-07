# AWS Secrets Manager values for the prod-1 cloudflare provider.
# Mirrors stage-1/secrets.tf. Terraform creates the secret container
# + a placeholder initial version, and `ignore_changes = [secret_string]`
# lets the real value be set out-of-band without terraform clobbering
# it on subsequent applies.
#
# First-apply flow (chicken-and-egg with the cloudflare provider):
#   1. `task tf-prod` — SM resources apply; the cloudflare provider
#      initializes with the placeholder token and every cloudflare_*
#      resource fails. Expected.
#   2. Populate the real value (same token used by stage-1; Pages:Edit
#      scope is account-wide, just stored in a second SM container):
#        aws-vault exec adanalife-prod -- aws secretsmanager put-secret-value \
#          --secret-id prod-1/cloudflare-api-token --secret-string "$CLOUDFLARE_API_TOKEN"
#   3. `task tf-prod` again — cloudflare provider auths, resources apply.

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
# terraform-side consumer (no data source, not in the CI IAM policy);
# the consumer is a future production OBS pod via ESO. The k8s/obs/
# name prefix puts this inside the ESOSecretsReader IAM scope
# (arn:aws:secretsmanager:*:*:secret:k8s/*) so it'll be readable
# without a bump when the platform stack lands here.
# Populate out-of-band:
#   aws-vault exec adanalife-prod -- aws secretsmanager put-secret-value \
#     --secret-id k8s/obs/twitch-stream-key --secret-string "$STREAM_KEY"
# Get the key from https://dashboard.twitch.tv/u/adanalife/settings/stream
resource "aws_secretsmanager_secret" "k8s_obs_twitch_stream_key" {
  name        = "k8s/obs/twitch-stream-key"
  description = "Twitch RTMP stream key for adanalife (production). Consumed by OBS via ESO. Rotate from the Twitch dashboard, then put-secret-value here."
}

resource "aws_secretsmanager_secret_version" "k8s_obs_twitch_stream_key" {
  secret_id     = aws_secretsmanager_secret.k8s_obs_twitch_stream_key.id
  secret_string = "placeholder — set via aws secretsmanager put-secret-value"
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Allow CITerraformRole to read this secret. ReadOnlyAccess (already
# attached) excludes secretsmanager:GetSecretValue, which the
# cloudflare provider's data source needs during `terraform plan` /
# drift in CI. Scoped to the specific ARN — CI can't read other
# secrets in the account, and can't create/put/delete anything.
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
