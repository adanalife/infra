# GitHub org config, managed through the adanalife-automation GitHub App.
#
# The provider auths AS the App (no PAT anywhere): the App's private key
# lives in SM (platform/github-automation-app-private-key, seeded out-of-band
# per secrets.tf), and the App ID / installation ID are plain config in
# terraform.tfvars. Bootstrap + rotation runbook:
# vault/infra/github-app-automation.md.
#
# The same App identity is fanned out to repo Actions so workflows mint
# short-lived installation tokens via actions/create-github-app-token —
# GITHUB_TOKEN can't be used for those jobs because commits/PRs it creates
# never trigger workflow runs, and cross-repo dispatch needs real auth.
# Consumers: infra cdk8s.yml (auto-synth push-back), infra bump-prs.yml
# (prod version-bump PRs), tripbot release.yml (repository_dispatch to infra).

provider "github" {
  owner = "adanalife"
  app_auth {
    id              = var.github_app_id
    installation_id = var.github_app_installation_id
    pem_file        = data.aws_secretsmanager_secret_version.github_automation_app_key.secret_string
  }
}

locals {
  # Repos the automation App serves; it must be installed on each.
  automation_repos = toset(["infra", "tripbot"])
}

# App ID is not sensitive → Actions variable (vars.AUTOMATION_APP_ID).
resource "github_actions_variable" "automation_app_id" {
  for_each      = local.automation_repos
  repository    = each.value
  variable_name = "AUTOMATION_APP_ID"
  value         = var.github_app_id
}

resource "github_actions_secret" "automation_app_private_key" {
  for_each        = local.automation_repos
  repository      = each.value
  secret_name     = "AUTOMATION_APP_PRIVATE_KEY"
  plaintext_value = data.aws_secretsmanager_secret_version.github_automation_app_key.secret_string
}
