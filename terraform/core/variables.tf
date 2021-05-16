locals {
  accounts = aws_organizations_account.account

  account_names = var.account_names

  account_name = "adanalife-core"

  core_account_id = data.aws_caller_identity.current.account_id
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket" {
  type        = string
  description = "The bucket in which Terraform stores state files"
}

variable "email_domain" {
  type        = string
  description = "The domain name for email addresses of created accounts"
}

variable "email_prefix" {
  type        = string
  description = "The prefix for account email addresses. Emails will be in the format <prefix><account name>@<domain>"
}

variable "domain" {
  type        = string
  description = "The domain name used for DNS"
}

variable "secondary_domain" {
  type        = string
  description = "The domain name used for secondary DNS"
}

variable "primary_prod_nameservers" {
  type    = list(string)
  default = []
}

variable "secondary_prod_nameservers" {
  type    = list(string)
  default = []
}

variable "primary_stage_nameservers" {
  type    = list(string)
  default = []
}

variable "secondary_stage_nameservers" {
  type    = list(string)
  default = []
}

variable "account_names" {
  type    = list(string)
  default = []
}

variable "admin_group" {
  type    = string
  default = "Admin"
}

variable "developer_group" {
  type    = string
  default = "Developer"
}

variable "admin_role" {
  type        = string
  default     = "AdminUser"
  description = "The name of the role which is created in child accounts in order to access them"
}

variable "developer_role" {
  type        = string
  default     = "DeveloperUser"
  description = "The name of the role which is created in child accounts in order to access them"
}

variable "primary_www_acm_dns_name" {
  type = string
}

variable "primary_www_acm_dns_record" {
  type = string
}

variable "primary_www_acm_dns_type" {
  type    = string
  default = "CNAME"
}

variable "primary_naked_acm_dns_name" {
  type = string
}

variable "primary_naked_acm_dns_record" {
  type = string
}

variable "primary_naked_acm_dns_type" {
  type    = string
  default = "CNAME"
}
