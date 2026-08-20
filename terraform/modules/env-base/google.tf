# GCP — a terraform-managed delegated identity, Workload Identity Federation
# for CI, and API enablement. The env difference is var.gcp_project
# (tripbot-stage vs tripbot-prod), set in each env's terraform.tfvars.
#
# The `provider "google"` block stays in the calling root (google.tf there),
# which is where its auth model and bootstrap sequence are documented. These
# resources inherit it: a module with no provider block of its own uses the
# default provider configuration of its caller.
#
# What terraform still does NOT own (and can't): the OAuth 2.0 Client ID, the
# OAuth consent screen, and the channel-owner refresh token. The google
# provider has no resource for general user-consent OAuth clients, and YouTube
# live-chat read/write must run as the channel owner via user consent (a
# service account can't operate a channel's live chat). Those stay manual.

# ---------------------------------------------------------------------------
# Delegated terraform identity
# ---------------------------------------------------------------------------

resource "google_service_account" "terraform" {
  project      = var.gcp_project
  account_id   = "terraform"
  display_name = "Terraform automation (managed by infra/terraform/${var.account_name})"
}

# The delegated admin role — the GCP analogue of the AWS AdminUser role.
resource "google_project_iam_member" "terraform_owner" {
  project = var.gcp_project
  role    = "roles/owner"
  member  = "serviceAccount:${google_service_account.terraform.email}"
}

# NOTE: the human -> SA token-creator grant (so you can impersonate the SA for
# local applies) is a one-time bootstrap gcloud step, NOT terraformed — see the
# BOOTSTRAP block in the root's google.tf. That keeps a personal email out of
# this public repo.

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
# google_apikeys_key is deferred.
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

# ---------------------------------------------------------------------------
# Workload Identity Federation — keyless in-cluster auth (Burrito's terraform
# plan runner -> a read-only SA)
# ---------------------------------------------------------------------------
#
# The second federation path into this project, and the reason Burrito can plan
# this workspace at all: the google provider needs credentials, and the CI pool
# above only trusts GitHub's issuer. Rather than mint an SA key for the cluster
# (which this repo's GCP auth model rules out), the minipc's
# own ServiceAccount issuer becomes an OIDC provider here — the runner pod
# projects a ServiceAccount token and trades it for a short-lived SA token.
#
# The cluster's issuer is a LAN address, so Google can't fetch its discovery
# document; jwks_json hands Google the signing keys directly, which is exactly
# what that field exists for. The JWKs are public verification material (the
# cluster serves them unauthenticated) — committing them leaks nothing. They
# change only if the control plane's ServiceAccount signing key is regenerated,
# i.e. a cluster rebuild; refresh with:
#   kubectl get --raw /openid/v1/jwks | python3 -m json.tool > minipc-jwks.json
locals {
  # `kubectl get --raw /.well-known/openid-configuration | jq -r .issuer`
  minipc_issuer_uri = "https://192.168.1.200:6443"
  # Short, project-number-free audience so the token projection in
  # cdk8s/adanalife_k8s/constructs/burrito.py stays readable.
  # KEEP-IN-SYNC with GCP_TOKEN_AUDIENCE there.
  burrito_token_audience = "adanalife-burrito"
}

resource "google_iam_workload_identity_pool" "minipc" {
  project                   = var.gcp_project
  workload_identity_pool_id = "minipc"
  display_name              = "minipc cluster"
  description               = "OIDC federation for workloads on the adanalife-minipc cluster"
}

resource "google_iam_workload_identity_pool_provider" "minipc" {
  project                            = var.gcp_project
  workload_identity_pool_id          = google_iam_workload_identity_pool.minipc.workload_identity_pool_id
  workload_identity_pool_provider_id = "minipc"
  display_name                       = "minipc OIDC"

  attribute_mapping = {
    "google.subject" = "assertion.sub"
  }
  # Only the Burrito runner's ServiceAccount may use the pool — every other
  # workload on the cluster projects a token with a different subject.
  attribute_condition = "assertion.sub == \"system:serviceaccount:burrito:burrito-runner\""

  oidc {
    issuer_uri        = local.minipc_issuer_uri
    allowed_audiences = [local.burrito_token_audience]
    jwks_json         = file("${path.module}/minipc-jwks.json")
  }
}

# Plan-only identity: roles/viewer, never roles/owner. This is the GCP half of
# the same property the read-only IAM user gives on the AWS side — the
# credential reachable from the cluster cannot change anything.
resource "google_service_account" "burrito_plan" {
  project      = var.gcp_project
  account_id   = "burrito-plan"
  display_name = "Burrito terraform plan (managed by infra/terraform/${var.account_name})"
}

resource "google_project_iam_member" "burrito_plan_viewer" {
  project = var.gcp_project
  role    = "roles/viewer"
  member  = "serviceAccount:${google_service_account.burrito_plan.email}"
}

resource "google_service_account_iam_member" "burrito_workload_identity" {
  service_account_id = google_service_account.burrito_plan.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.minipc.name}/subject/system:serviceaccount:burrito:burrito-runner"
}

# Consumed by the runner's external_account credential config — see
# cdk8s/adanalife_k8s/constructs/burrito.py, which hardcodes these (a cdk8s
# manifest can't read terraform outputs). Surfaced so a mismatch is one
# `terraform output` away from being caught.
output "burrito_wif_audience" {
  value = "//iam.googleapis.com/${google_iam_workload_identity_pool_provider.minipc.name}"
}

output "burrito_plan_service_account" {
  value = google_service_account.burrito_plan.email
}
