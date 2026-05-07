# AWS Secrets Manager values consumed by other resources in this
# workspace. Terraform creates the secret container + a placeholder
# initial version, then `ignore_changes = [secret_string]` lets the
# real value be set out-of-band (console, `aws secretsmanager
# put-secret-value`, or `task update-allowlist`) without terraform
# trying to clobber it on the next apply.
#
# First-apply flow (chicken-and-egg with the cloudflare provider):
#   1. `task tf-stage` — SM resources apply cleanly; the cloudflare
#      provider initializes with the placeholder token and every
#      cloudflare_* resource fails. Expected.
#   2. Populate the real values:
#        aws-vault exec adanalife-stage -- aws secretsmanager put-secret-value \
#          --secret-id stage-1/cloudflare-api-token --secret-string "$CLOUDFLARE_API_TOKEN"
#        task update-allowlist   # writes ["X.X.X.X/32"] to stage-1/allowlist-cidrs
#   3. `task tf-stage` again — cloudflare provider auths, resources apply.

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

# JSON array of CIDR strings, e.g. ["69.222.113.215/32"]. Edited
# interactively via `task update-allowlist`. Consumed by the
# Cloudflare Access policy on tripbot — see cloudflare-tunnel.tf.
resource "aws_secretsmanager_secret" "stage_1_allowlist_cidrs" {
  name        = "stage-1/allowlist-cidrs"
  description = "Allowlisted CIDRs for Cloudflare Access on tripbot.whalecore.com. JSON array of CIDR strings."
}

resource "aws_secretsmanager_secret_version" "stage_1_allowlist_cidrs" {
  secret_id     = aws_secretsmanager_secret.stage_1_allowlist_cidrs.id
  secret_string = "[]"
  lifecycle {
    ignore_changes = [secret_string]
  }
}

data "aws_secretsmanager_secret_version" "stage_1_allowlist_cidrs" {
  secret_id = aws_secretsmanager_secret.stage_1_allowlist_cidrs.id
}

# Twitch RTMP ingest key for the adanalife_staging channel. No
# terraform-side consumer (no data source, not in the CI IAM policy);
# the consumer is the OBS pod via ESO once the platform stack lands —
# the k8s/obs/ name prefix puts this inside the ESOSecretsReader IAM
# scope (arn:aws:secretsmanager:*:*:secret:k8s/*) without a bump.
# Populate out-of-band:
#   aws-vault exec adanalife-stage -- aws secretsmanager put-secret-value \
#     --secret-id k8s/obs/twitch-stream-key --secret-string "$STREAM_KEY"
# Get the key from https://dashboard.twitch.tv/u/adanalife_staging/settings/stream
resource "aws_secretsmanager_secret" "k8s_obs_twitch_stream_key" {
  name        = "k8s/obs/twitch-stream-key"
  description = "Twitch RTMP stream key for adanalife_staging. Consumed by OBS via ESO. Rotate from the Twitch dashboard, then put-secret-value here."
}

resource "aws_secretsmanager_secret_version" "k8s_obs_twitch_stream_key" {
  secret_id     = aws_secretsmanager_secret.k8s_obs_twitch_stream_key.id
  secret_string = "placeholder — set via aws secretsmanager put-secret-value"
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Allow CITerraformRole to read just these two secrets. ReadOnlyAccess
# (already attached) excludes secretsmanager:GetSecretValue, which the
# cloudflare provider's data source needs during `terraform plan` /
# drift in CI. Scoped to the specific ARNs — CI can't read other
# secrets in the account, and can't create/put/delete anything (so
# `task tf-stage` on a SM-touching change has to run locally).
data "aws_iam_policy_document" "ci_terraform_secrets_read" {
  statement {
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecretVersionIds",
    ]
    resources = [
      aws_secretsmanager_secret.cloudflare_api_token.arn,
      aws_secretsmanager_secret.stage_1_allowlist_cidrs.arn,
    ]
  }
}

resource "aws_iam_policy" "ci_terraform_secrets_read" {
  name        = "AllowCITerraformReadStage1Secrets"
  description = "Read-only access for CITerraformRole to the two SM secrets managed by terraform/stage-1/secrets.tf"
  policy      = data.aws_iam_policy_document.ci_terraform_secrets_read.json
}

resource "aws_iam_role_policy_attachment" "ci_terraform_secrets_read" {
  role       = aws_iam_role.ci_terraform.name
  policy_arn = aws_iam_policy.ci_terraform_secrets_read.arn
}
