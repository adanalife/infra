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
