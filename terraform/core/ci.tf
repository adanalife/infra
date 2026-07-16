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

# State moves from the pre-module flat layout; safe to delete once
# core has applied.

moved {
  from = aws_iam_user.ci
  to   = module.ci.aws_iam_user.ci
}

moved {
  from = aws_iam_access_key.ci
  to   = module.ci.aws_iam_access_key.ci
}

moved {
  from = aws_iam_role.ci
  to   = module.ci.aws_iam_role.ci
}

moved {
  from = aws_iam_policy.ci
  to   = module.ci.aws_iam_policy.ci
}

moved {
  from = aws_iam_user_policy_attachment.ci
  to   = module.ci.aws_iam_user_policy_attachment.ci
}

moved {
  from = aws_iam_role_policy_attachment.ci_role_access
  to   = module.ci.aws_iam_role_policy_attachment.ci_role_access
}

moved {
  from = aws_iam_role.ci_terraform
  to   = module.ci.aws_iam_role.ci_terraform
}

moved {
  from = aws_iam_role_policy_attachment.ci_terraform_managed_policy
  to   = module.ci.aws_iam_role_policy_attachment.ci_terraform_managed_policy
}

moved {
  from = aws_iam_policy.ci_terraform_assume_role
  to   = module.ci.aws_iam_policy.ci_terraform_assume_role
}

moved {
  from = aws_iam_user_policy_attachment.ci_terraform
  to   = module.ci.aws_iam_user_policy_attachment.ci_terraform
}
