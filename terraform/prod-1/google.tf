# GCP — google provider, terraform-managed service account, + API enablement
# for tripbot-prod. prod-only (YouTube v1 is prod-only).
#
# AUTH MODEL (deliberate exception to secrets-manager-for-tf-providers):
# Terraform creates its own automation service account + key and writes the
# key into AWS SM itself — it does NOT use the out-of-band placeholder seed.
# To avoid the chicken-and-egg (the provider can't authenticate as the SA it's
# creating), the provider authenticates via Application Default Credentials:
#   - locally: `gcloud auth application-default login` (one-time, as a
#     project owner/editor — Dana). This is the only manual bootstrap step.
#   - in CI: the plan job exports GOOGLE_CREDENTIALS from the SM secret this
#     file populates (see .github/workflows/terraform.yml + secrets.tf).
# No `credentials` argument here, so both paths resolve through the google
# provider's standard ADC / GOOGLE_CREDENTIALS lookup.
#
# The provider lives in google.tf (not providers.tf) so prod-1's KEEP-IN-SYNC
# providers.tf stays byte-identical to stage-1, which has no GCP resources —
# same reasoning the cloudflare provider lives in cloudflare-pages.tf.
#
# What terraform still does NOT own (and can't): the OAuth 2.0 Client ID, the
# OAuth consent screen, and the channel-owner refresh token. The google
# provider has no resource for general user-consent OAuth clients, and YouTube
# live-chat read/write must run as the channel owner via user consent (a
# service account can't operate a channel's live chat). Those stay manual.

provider "google" {
  project = "tripbot-prod"
}

# Automation service account terraform uses for steady-state / CI plan. Created
# by Dana's ADC on first apply; thereafter the key below credentials CI.
resource "google_service_account" "terraform" {
  project      = "tripbot-prod"
  account_id   = "terraform"
  display_name = "Terraform automation (managed by infra/terraform/prod-1)"
}

# serviceUsageAdmin lets the SA enable/inspect the google_project_service
# resources below. apikeys.admin (for the deferred google_apikeys_key Maps
# import — TODO #188) is intentionally NOT granted yet.
resource "google_project_iam_member" "terraform_serviceusage" {
  project = "tripbot-prod"
  role    = "roles/serviceusage.serviceUsageAdmin"
  member  = "serviceAccount:${google_service_account.terraform.email}"
}

# Key for the SA. `private_key` is base64 JSON, surfaced only at create time and
# kept in terraform state (S3, encrypted) — written into SM by secrets.tf.
resource "google_service_account_key" "terraform" {
  service_account_id = google_service_account.terraform.name
}

# YouTube Data API — the resource this whole workspace-addition exists to
# enable. Prerequisite for the tripbot YouTube provider's OAuth + live-chat
# polling.
resource "google_project_service" "youtube" {
  project = "tripbot-prod"
  service = "youtube.googleapis.com"

  # Never tear down an enabled API on resource removal / destroy — other things
  # (the live Maps key) depend on these being on.
  disable_on_destroy = false
}

# Maps JavaScript + Geocoding APIs — declaratively enable the APIs the existing
# prod Maps key is restricted to. The KEY itself stays on the gcloud Taskfile
# target (task gcp:prod:mint-maps-key) for now; importing it into
# google_apikeys_key is deferred (vault/infra/TODO.md #188).
resource "google_project_service" "maps_javascript" {
  project            = "tripbot-prod"
  service            = "maps-backend.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "geocoding" {
  project            = "tripbot-prod"
  service            = "geocoding-backend.googleapis.com"
  disable_on_destroy = false
}
