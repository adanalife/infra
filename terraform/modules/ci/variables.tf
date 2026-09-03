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

# Empty (the default) creates no OIDC provider and adds no trust statement, so
# an account opts in by naming the workflows allowed to federate. Entries are
# GitHub `sub` claims and may use `*`, e.g. "repo:adanalife/infra:*" for any
# ref in that repo, or "repo:adanalife/infra:ref:refs/heads/main" to require a
# branch. Wildcards are matched with StringLike; exact values still match.
variable "github_oidc_subjects" {
  type        = list(string)
  default     = []
  description = "GitHub Actions OIDC `sub` claims allowed to assume CITerraformRole; empty disables OIDC entirely"
}
