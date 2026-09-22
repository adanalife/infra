# KEEP-IN-SYNC: terraform/{stage-1,prod-1}/google.tf
#
# The google provider config. The GCP resources it serves live in the env-base
# module (modules/env-base/google.tf) — they carry no provider block of their
# own, so they inherit this one. Provider config stays root-side because the
# credentials are per-env; the resources are not.
#
# AUTH MODEL (mirrors the AWS "assume a delegated role, never act as root"
# pattern — see providers.tf's assume_role into AdminUser):
#   - Each project has a `terraform` service account holding roles/owner. That
#     SA is the apply identity; the human owner never applies directly.
#   - Locally: your ADC (`gcloud auth application-default login`) impersonates
#     the SA. The human -> SA token-creator grant is a one-time BOOTSTRAP step
#     (gcloud, below), deliberately NOT terraformed — it's a personal grant, and
#     keeping it out of this (public) repo avoids committing a personal email.
#   - In CI: GitHub OIDC -> Workload Identity Federation auths AS the SA, keyless
#     (no SA key anywhere). See .github/workflows/terraform.yml.
# The provider's impersonate_service_account is gated by var.gcp_impersonate so
# the bootstrap apply (and CI) can run without it — see that variable's doc.
#
# BOOTSTRAP (out-of-band, before the first apply — your email stays in your
# shell, never committed):
#   # 1. APIs terraform needs before it can manage project services:
#   gcloud services enable serviceusage.googleapis.com \
#     cloudresourcemanager.googleapis.com --project <gcp_project>
#   # 2. let yourself impersonate the SA for local applies (after the first
#   #    `apply -var gcp_impersonate=false` creates it):
#   gcloud iam service-accounts add-iam-policy-binding \
#     terraform@<gcp_project>.iam.gserviceaccount.com \
#     --member user:<you@example.com> \
#     --role roles/iam.serviceAccountTokenCreator

provider "google" {
  project                     = var.gcp_project
  impersonate_service_account = var.gcp_impersonate ? "terraform@${var.gcp_project}.iam.gserviceaccount.com" : null
}
