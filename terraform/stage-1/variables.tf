# prod, stage, dev
variable environment {
  type = string
}

variable label {
  type        = string
  description = "An identifier for this particular environment"
  default     = "1"
}

variable region {
  type    = string
  default = "us-east-1"
}

variable core_account_id {
  type        = string
  description = "The AWS account ID for the core account"
}

variable primary_domain {
  type        = string
  description = "The domain name used for DNS"
}

variable secondary_domain {
  type        = string
  description = "The domain name used for secondary DNS"
}

variable external_dns_role {
  type    = string
  default = "ExternalDNSRole"
}

variable rds_tripbot_username {
  type = string
}

variable rds_tripbot_password {
  type = string
}

locals {
  org_name = "adanalife"
  # this is how we will refer to the account in other places
  account_name      = "${var.environment}-${var.label}"
  full_account_name = "${local.org_name}-${var.environment}-${var.label}"
}
