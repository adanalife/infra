provider "aws" {
  alias  = "stage_1"
  region = var.region

  assume_role {
    role_arn = "arn:aws:iam::${var.core_account_id}:role/AdminUser"
  }
}

# Token sourced from AWS Secrets Manager — see secrets.tf for the
# bootstrap flow. CLOUDFLARE_API_TOKEN env var is no longer used.
provider "cloudflare" {
  api_token = data.aws_secretsmanager_secret_version.cloudflare_api_token.secret_string
}

# this lets us get the current account_id
data "aws_caller_identity" "current" {}

# this lets us get the current AWS region
data "aws_region" "current" {}

# this lets us get all available AZs
data "aws_availability_zones" "available" {
  state = "available"
}

# set the AWS account alias
resource "aws_iam_account_alias" "alias" {
  account_alias = local.full_account_name
}
