# Mirrors the naming inputs of terraform/prod-1 rather than hardcoding
# `adanalife-prod-1`, so the stage-1-data sibling is this directory plus a
# one-line terraform.tfvars.

# prod, stage, dev
variable "environment" {
  type = string
}

variable "label" {
  type        = string
  description = "An identifier for this particular environment"
  default     = "1"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

locals {
  org_name = "adanalife"
  # this is how we will refer to the account in other places
  full_account_name = "${local.org_name}-${var.environment}-${var.label}"
}
