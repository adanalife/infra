# KEEP-IN-SYNC: terraform/{stage-1,prod-1}/providers.tf
#
# De-symlinked 2026-05-11. Stage-1 and prod-1 are intentionally near-identical
# until the modules refactor lands (vault/infra/TODO.md). Any structural
# change here SHOULD be mirrored to the sibling file unless the divergence
# is the whole point of the change.

provider "aws" {
  alias  = "stage_1"
  region = var.region

  assume_role {
    role_arn = "arn:aws:iam::${var.core_account_id}:role/AdminUser"
  }
}

# The cloudflare provider lives in cloudflare-pages.tf so that prod-1
# (which symlinks this file) doesn't inherit it — prod-1 has no
# Cloudflare resources today.

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
