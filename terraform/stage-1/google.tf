# GCP — google provider, a terraform-managed delegated identity, Workload
# Identity Federation for CI, and API enablement. KEEP-IN-SYNC sibling of
# terraform/stage-1/google.tf — identical except for var.gcp_project
# (tripbot-prod here, tripbot-stage there).
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
# the bootstrap apply (and CI) can run without it — see that variable's doc and
# the bootstrap sequence in the PR description.
#
# The provider lives here (not providers.tf) so prod-1's KEEP-IN-SYNC
# providers.tf stays identical to stage-1.
#
# What terraform still does NOT own (and can't): the OAuth 2.0 Client ID, the
# OAuth consent screen, and the channel-owner refresh token. The google
# provider has no resource for general user-consent OAuth clients, and YouTube
# live-chat read/write must run as the channel owner via user consent (a
# service account can't operate a channel's live chat). Those stay manual.
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

data "google_project" "this" {
  project_id = var.gcp_project
}

# ---------------------------------------------------------------------------
# Delegated terraform identity
# ---------------------------------------------------------------------------

resource "google_service_account" "terraform" {
  project      = var.gcp_project
  account_id   = "terraform"
  display_name = "Terraform automation (managed by infra/terraform/${var.environment}-${var.label})"
}

# The delegated admin role — the GCP analogue of the AWS AdminUser role.
resource "google_project_iam_member" "terraform_owner" {
  project = var.gcp_project
  role    = "roles/owner"
  member  = "serviceAccount:${google_service_account.terraform.email}"
}

# NOTE: the human -> SA token-creator grant (so you can impersonate the SA for
# local applies) is a one-time bootstrap gcloud step, NOT terraformed — see the
# BOOTSTRAP block in this file's header. That keeps a personal email out of this
# public repo.

# ---------------------------------------------------------------------------
# Workload Identity Federation — keyless CI auth (GitHub OIDC -> the SA)
# ---------------------------------------------------------------------------

resource "google_iam_workload_identity_pool" "github" {
  project                   = var.gcp_project
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"
  description               = "OIDC federation for adanalife/infra CI"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.gcp_project
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
  }
  # Only tokens minted for this repo can use the pool.
  attribute_condition = "assertion.repository == \"adanalife/infra\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# CI (any workflow run in adanalife/infra) may auth AS the terraform SA.
resource "google_service_account_iam_member" "ci_workload_identity" {
  service_account_id = google_service_account.terraform.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/adanalife/infra"
}

# ---------------------------------------------------------------------------
# API enablement
# ---------------------------------------------------------------------------
#
# youtube/maps/geocoding are the app-facing APIs; the rest are the meta-APIs
# terraform's own auth model (impersonation + WIF) depends on. The Maps *key*
# itself stays on the gcloud Taskfile target for now; importing it into
# google_apikeys_key is deferred (vault/infra/TODO.md #188).
# disable_on_destroy=false — never tear an enabled API down on resource removal.
resource "google_project_service" "apis" {
  for_each = toset([
    "youtube.googleapis.com",
    "maps-backend.googleapis.com",
    "geocoding-backend.googleapis.com",
    "serviceusage.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
  ])

  project            = var.gcp_project
  service            = each.value
  disable_on_destroy = false
}
