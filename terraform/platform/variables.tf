variable "region" {
  type    = string
  default = "us-east-1"
}

# --- GitHub automation App (github.tf) ---
# Both values come from the app's settings page after the one-time manual
# creation.

variable "github_app_id" {
  description = "App ID of the adanalife-automation GitHub App."
  type        = string
}

variable "github_app_client_id" {
  description = "Client ID of the adanalife-automation GitHub App (Iv…, from the App settings page). actions/create-github-app-token takes it in place of the deprecated App ID."
  type        = string
}

variable "github_app_installation_id" {
  description = "Installation ID of the adanalife-automation App on the adanalife org (from the installation page URL)."
  type        = string
}

# Identifier, not a credential — the D1 REST URL the guessr Grafana datasource
# queries names the account in its path (grafana-guessr.tf).
variable "cloudflare_account_id" {
  description = "Cloudflare account ID"
  type        = string
}
