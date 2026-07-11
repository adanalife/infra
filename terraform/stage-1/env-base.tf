# KEEP-IN-SYNC: terraform/{stage-1,prod-1}/env-base.tf
#
# Everything stage and prod provision identically lives in the env-base
# module; this file is just the per-env call. Env-specific resources
# belong in this root directory, not in the module.

module "env_base" {
  source = "../modules/env-base"

  core_account_id                    = var.core_account_id
  external_dns_role                  = var.external_dns_role
  primary_subdomain                  = local.primary_subdomain
  secondary_subdomain                = local.secondary_subdomain
  static_site_public_dir             = var.static_site_public_dir
  primary_acm_cert_alternative_names = var.primary_acm_cert_alternative_names
}

# State moves from the pre-module flat layout; safe to delete once both
# envs have applied.

moved {
  from = module.default_vpc
  to   = module.env_base.module.default_vpc
}

moved {
  from = random_password.static_site_secret
  to   = module.env_base.random_password.static_site_secret
}

moved {
  from = random_password.tripbot_db
  to   = module.env_base.random_password.tripbot_db
}

moved {
  from = aws_db_instance.tripbot
  to   = module.env_base.aws_db_instance.tripbot
}

moved {
  from = aws_security_group.allow_postgres
  to   = module.env_base.aws_security_group.allow_postgres
}

moved {
  from = aws_acm_certificate.primary_static_site
  to   = module.env_base.aws_acm_certificate.primary_static_site
}

moved {
  from = aws_s3_bucket.static_website
  to   = module.env_base.aws_s3_bucket.static_website
}

moved {
  from = aws_s3_bucket_website_configuration.static_website
  to   = module.env_base.aws_s3_bucket_website_configuration.static_website
}

moved {
  from = aws_s3_bucket_policy.static_website_read_with_secret
  to   = module.env_base.aws_s3_bucket_policy.static_website_read_with_secret
}

moved {
  from = aws_cloudfront_distribution.primary_cdn
  to   = module.env_base.aws_cloudfront_distribution.primary_cdn
}

moved {
  from = aws_route53_zone.primary_subdomain_zone
  to   = module.env_base.aws_route53_zone.primary_subdomain_zone
}

moved {
  from = aws_route53_zone.secondary_subdomain_zone
  to   = module.env_base.aws_route53_zone.secondary_subdomain_zone
}

moved {
  from = aws_route53_record.primary_static_site
  to   = module.env_base.aws_route53_record.primary_static_site
}

moved {
  from = aws_iam_user.ci
  to   = module.env_base.module.ci.aws_iam_user.ci
}

moved {
  from = aws_iam_access_key.ci
  to   = module.env_base.module.ci.aws_iam_access_key.ci
}

moved {
  from = aws_iam_role.ci
  to   = module.env_base.module.ci.aws_iam_role.ci
}

moved {
  from = aws_iam_policy.ci
  to   = module.env_base.module.ci.aws_iam_policy.ci
}

moved {
  from = aws_iam_user_policy_attachment.ci
  to   = module.env_base.module.ci.aws_iam_user_policy_attachment.ci
}

moved {
  from = aws_iam_role_policy_attachment.ci_role_access
  to   = module.env_base.module.ci.aws_iam_role_policy_attachment.ci_role_access
}

moved {
  from = aws_iam_role.ci_terraform
  to   = module.env_base.module.ci.aws_iam_role.ci_terraform
}

moved {
  from = aws_iam_role_policy_attachment.ci_terraform_managed_policy
  to   = module.env_base.module.ci.aws_iam_role_policy_attachment.ci_terraform_managed_policy
}

moved {
  from = aws_iam_policy.ci_terraform_assume_role
  to   = module.env_base.module.ci.aws_iam_policy.ci_terraform_assume_role
}

moved {
  from = aws_iam_user_policy_attachment.ci_terraform
  to   = module.env_base.module.ci.aws_iam_user_policy_attachment.ci_terraform
}

moved {
  from = aws_iam_role.developer_role
  to   = module.env_base.aws_iam_role.developer_role
}

moved {
  from = aws_iam_policy.developer_role
  to   = module.env_base.aws_iam_policy.developer_role
}

moved {
  from = aws_iam_role_policy_attachment.developer_role
  to   = module.env_base.aws_iam_role_policy_attachment.developer_role
}

moved {
  from = aws_iam_policy.basic_web_console_viewing
  to   = module.env_base.aws_iam_policy.basic_web_console_viewing
}

moved {
  from = aws_iam_role_policy_attachment.basic_web_console_viewing
  to   = module.env_base.aws_iam_role_policy_attachment.basic_web_console_viewing
}

moved {
  from = aws_iam_user.external_dns
  to   = module.env_base.aws_iam_user.external_dns
}

moved {
  from = aws_iam_access_key.external_dns
  to   = module.env_base.aws_iam_access_key.external_dns
}

moved {
  from = aws_iam_user_policy_attachment.external_dns
  to   = module.env_base.aws_iam_user_policy_attachment.external_dns
}

moved {
  from = aws_iam_role.external_dns
  to   = module.env_base.aws_iam_role.external_dns
}

moved {
  from = aws_iam_role_policy_attachment.external_dns
  to   = module.env_base.aws_iam_role_policy_attachment.external_dns
}

moved {
  from = aws_iam_policy.allow_external_dns_updates
  to   = module.env_base.aws_iam_policy.allow_external_dns_updates
}
