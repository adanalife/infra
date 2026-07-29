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
  gcp_project                        = var.gcp_project
  primary_subdomain                  = local.primary_subdomain
  secondary_subdomain                = local.secondary_subdomain
  static_site_public_dir             = var.static_site_public_dir
  primary_acm_cert_alternative_names = var.primary_acm_cert_alternative_names
}

# Delete once both roots have applied, per the gate in
# decisions/terraform-shared-env-modules.

moved {
  from = google_service_account.terraform
  to   = module.env_base.google_service_account.terraform
}

moved {
  from = google_project_iam_member.terraform_owner
  to   = module.env_base.google_project_iam_member.terraform_owner
}

moved {
  from = google_iam_workload_identity_pool.github
  to   = module.env_base.google_iam_workload_identity_pool.github
}

moved {
  from = google_iam_workload_identity_pool_provider.github
  to   = module.env_base.google_iam_workload_identity_pool_provider.github
}

moved {
  from = google_service_account_iam_member.ci_workload_identity
  to   = module.env_base.google_service_account_iam_member.ci_workload_identity
}

# for_each resource — a whole-resource move carries every instance key with it.
moved {
  from = google_project_service.apis
  to   = module.env_base.google_project_service.apis
}
