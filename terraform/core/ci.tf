# CI identities come from the shared ci module. Core has no static
# website, so the S3/CloudFront statements are skipped (null ARNs).
module "ci" {
  source = "../modules/ci"
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
