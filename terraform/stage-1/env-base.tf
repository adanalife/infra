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

  # A deliberate divergence from the prod-1 sibling, not drift: stage is where
  # a broken trust policy is cheap to discover, so keyless CI auth proves out
  # here before prod-1 or core opt in. Mirror this line once the infra
  # workflows actually federate into stage.
  github_oidc_subjects = ["repo:adanalife/infra:*"]
}
