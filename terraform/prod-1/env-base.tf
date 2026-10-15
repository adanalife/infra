# KEEP-IN-SYNC: terraform/{stage-1,prod-1}/env-base.tf
#
# Everything stage and prod provision identically lives in the env-base
# module; this file is just the per-env call. Env-specific resources
# belong in this root directory, not in the module.

module "env_base" {
  source = "../modules/env-base"

  account_name                       = local.account_name
  core_account_id                    = var.core_account_id
  full_account_name                  = local.full_account_name
  gcp_project                        = var.gcp_project
  primary_subdomain                  = local.primary_subdomain
  secondary_subdomain                = local.secondary_subdomain
  static_site_public_dir             = var.static_site_public_dir
  primary_acm_cert_alternative_names = var.primary_acm_cert_alternative_names

  # The uuid gcloud gave the key when it was minted by hand on 2026-05-18
  # (display name tripbot-prod-1); maps-api-key.tf imports it under this id.
  maps_api_key_name = "2a87a600-38b5-4a5f-a6bb-d917206a286a"
}
