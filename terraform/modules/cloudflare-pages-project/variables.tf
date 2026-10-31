variable "account_id" {
  type        = string
  description = "Cloudflare account ID"
}

variable "project_name" {
  type        = string
  description = "Cloudflare Pages project name. Also the pages.dev subdomain, which is a global namespace."
}

variable "production_branch" {
  type        = string
  description = "Git branch the Pages project treats as production. What `wrangler pages deploy --branch` targets, unrelated to the branch CI deploys from."
  default     = "main"
}

variable "domains" {
  type        = list(string)
  description = "Custom hostnames to bind to the project. A hostname whose zone is not in Cloudflare still needs a CNAME in whichever provider is authoritative — that record is what validates the TLS cert."
  default     = []
}

variable "dns_record" {
  type = object({
    zone_id = string
    name    = string
  })
  description = "Proxied CNAME to create for a custom domain whose zone Cloudflare is authoritative for. Null when every domain's DNS lives elsewhere."
  default     = null
}
