# KEEP-IN-SYNC: terraform/{stage-1,prod-1}/env-base.tf
#
# Everything stage and prod provision identically lives in the env-base
# module; this file is just the per-env call. Env-specific resources
# belong in this root directory, not in the module.

module "env_base" {
  source = "../modules/env-base"

  account_name                       = local.account_name
  core_account_id                    = var.core_account_id
  external_dns_role                  = var.external_dns_role
  full_account_name                  = local.full_account_name
  primary_subdomain                  = local.primary_subdomain
  secondary_subdomain                = local.secondary_subdomain
  static_site_public_dir             = var.static_site_public_dir
  primary_acm_cert_alternative_names = var.primary_acm_cert_alternative_names
}

# Delete once both roots have applied — a `moved` block whose `from` address
# is already gone from state is a no-op, and leaving them accumulates debris.

moved {
  from = aws_s3_bucket.postgres_wal
  to   = module.env_base.aws_s3_bucket.postgres_wal
}

moved {
  from = aws_s3_bucket_versioning.postgres_wal
  to   = module.env_base.aws_s3_bucket_versioning.postgres_wal
}

moved {
  from = aws_s3_bucket_public_access_block.postgres_wal
  to   = module.env_base.aws_s3_bucket_public_access_block.postgres_wal
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.postgres_wal
  to   = module.env_base.aws_s3_bucket_server_side_encryption_configuration.postgres_wal
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.postgres_wal
  to   = module.env_base.aws_s3_bucket_lifecycle_configuration.postgres_wal
}

moved {
  from = aws_iam_user.postgres_wal
  to   = module.env_base.aws_iam_user.postgres_wal
}

moved {
  from = aws_iam_access_key.postgres_wal
  to   = module.env_base.aws_iam_access_key.postgres_wal
}

moved {
  from = aws_iam_user_policy.postgres_wal
  to   = module.env_base.aws_iam_user_policy.postgres_wal
}

moved {
  from = aws_ssm_parameter.postgres_wal_s3
  to   = module.env_base.aws_ssm_parameter.postgres_wal_s3
}

moved {
  from = aws_iam_user.eso_reader
  to   = module.env_base.aws_iam_user.eso_reader
}

moved {
  from = aws_iam_access_key.eso_reader
  to   = module.env_base.aws_iam_access_key.eso_reader
}

moved {
  from = aws_iam_policy.allow_eso_read_k8s_secrets
  to   = module.env_base.aws_iam_policy.allow_eso_read_k8s_secrets
}

moved {
  from = aws_iam_user_policy_attachment.eso_reader
  to   = module.env_base.aws_iam_user_policy_attachment.eso_reader
}
