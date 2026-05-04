variable "cloudflare_account_id" {
  type        = string
  description = "Cloudflare account ID"
}

variable "project_name" {
  type        = string
  description = "Cloudflare Pages project name"
}

variable "github_repo_owner" {
  type        = string
  description = "GitHub repository owner"
  default     = "adanalife"
}

variable "github_repo_name" {
  type        = string
  description = "GitHub repository name"
  default     = "website"
}

variable "production_branch" {
  type        = string
  description = "Git branch used for production deployments"
  default     = "master"
}

# Sourced from a gitignored home_cidrs.auto.tfvars that the
# `tf-cloudflare` Taskfile target rewrites from `curl ifconfig.me`
# on every invocation. Marked sensitive so the value is redacted
# from `terraform plan` / `apply` output.
variable "home_cidrs" {
  type        = list(string)
  sensitive   = true
  description = "CIDRs allowed past Cloudflare Access for tripbot stage-1"
}
