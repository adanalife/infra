# GCP — google provider + API enablement for tripbot-prod.
#
# prod-only. The provider lives here (not providers.tf) so prod-1's
# KEEP-IN-SYNC providers.tf stays byte-identical to stage-1, which has no GCP
# resources — same reasoning the cloudflare provider lives in cloudflare-pages.tf.
#
# Credentialed out of AWS Secrets Manager via the placeholder-plus-out-of-band
# pattern (vault/decisions/secrets-manager-for-tf-providers); the SA-key
# container + bootstrap steps are in secrets.tf
# (aws_secretsmanager_secret.gcp_terraform_credentials).
#
# Two-phase first apply: the credential is a placeholder until seeded, so apply
# the SM container (secrets.tf) FIRST, run put-secret-value, THEN apply this
# file — otherwise the provider can't authenticate. See the commit history /
# the GCP-via-Terraform plan for the sequence.
#
# What terraform does NOT own (and can't): the OAuth 2.0 Client ID, the OAuth
# consent screen, and the channel-owner refresh token. The google provider has
# no resource for general user-consent OAuth clients, and YouTube live-chat
# read/write must run as the channel owner via user consent (a service account
# can't operate a channel's live chat). Those stay manual/console — runbook in
# the vault.

provider "google" {
  project     = "tripbot-prod"
  credentials = data.aws_secretsmanager_secret_version.gcp_terraform_credentials.secret_string
}

# YouTube Data API — the resource this whole workspace-addition exists to
# enable. Prerequisite for the tripbot YouTube provider's OAuth + live-chat
# polling (tripbot Track B, phase B1).
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
