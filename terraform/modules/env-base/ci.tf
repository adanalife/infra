# CI identities come from the shared ci module (also used standalone by
# core, which has no static site).
module "ci" {
  source = "../ci"

  static_website_bucket_arn = aws_s3_bucket.static_website.arn
  cdn_arn                   = aws_cloudfront_distribution.primary_cdn.arn
  github_oidc_subjects      = var.github_oidc_subjects
}

output "ci_user_access_key" {
  value     = module.ci.ci_user_access_key
  sensitive = true
}

# the PGP-encrypted secret
output "ci_user_secret" {
  value     = module.ci.ci_user_secret
  sensitive = true
}

output "ci_role_arn" {
  value = module.ci.ci_role_arn
}
