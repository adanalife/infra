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

# Pass via env: TF_VAR_home_cidrs='["203.0.113.42/32"]'
# Get current public IP: curl ifconfig.me
variable "home_cidrs" {
  type        = list(string)
  description = "CIDRs allowed past Cloudflare Access for tripbot stage-1"
}
