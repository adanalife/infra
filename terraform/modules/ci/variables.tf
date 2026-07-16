# The CI identities (CIUser, CIRole, CITerraformRole) every account
# provisions. The static-site ARNs are null in accounts (core) that have
# no static website; the S3/CloudFront statements are skipped there.

variable "static_website_bucket_arn" {
  type        = string
  default     = null
  description = "ARN of the static-site bucket CI deploys to; null if the account has none"
}

variable "cdn_arn" {
  type        = string
  default     = null
  description = "ARN of the CloudFront distribution CI invalidates; null if the account has none"
}
