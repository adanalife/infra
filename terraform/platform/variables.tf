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

variable "github_app_installation_id" {
  description = "Installation ID of the adanalife-automation App on the adanalife org (from the installation page URL)."
  type        = string
}
