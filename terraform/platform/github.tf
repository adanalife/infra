# GitHub org config, managed through the adanalife-automation GitHub App.
#
# The provider auths AS the App (no PAT anywhere): the App's private key
# lives in SM (platform/github-automation-app-private-key, seeded out-of-band
# per secrets.tf), and the App ID / installation ID are plain config in
# terraform.tfvars.
#
# Required App repository permissions: Contents r/w, Pull requests r/w
# (workflow pushes/PRs), plus Secrets r/w and Variables r/w (so terraform
# can manage the Actions credentials below). Permission changes on the App
# must be approved on the installation before tokens carry them.
#
# The same App identity is fanned out to repo Actions so workflows mint
# short-lived installation tokens via actions/create-github-app-token —
# GITHUB_TOKEN can't be used for those jobs because commits/PRs it creates
# never trigger workflow runs, and cross-repo dispatch needs real auth.
# Consumers: infra cdk8s-synth.yml (auto-synth push-back), infra bump-prs.yml
# (prod version-bump PRs), tripbot release.yml (repository_dispatch to infra),
# and release-please.yml in the release repos — as an ordinary actor the App
# gets the release PR's checks run unheld (github-actions[bot] parks them at
# action_required) and its tag fires release.yml without an explicit dispatch.

provider "github" {
  owner = "adanalife"
  app_auth {
    id              = var.github_app_id
    installation_id = var.github_app_installation_id
    pem_file        = data.aws_ssm_parameter.github_automation_app_key.value
  }
}

locals {
  # Repos the automation App serves; it must be installed on each.
  automation_repos = toset([
    "infra",
    "tripbot",
    "tripbot-console",
    "obs",
    "platform-gateway",
    "website",
    "video-pipeline",
    "guessr",
  ])
}

# App ID is not sensitive → Actions variable (vars.AUTOMATION_APP_ID).
resource "github_actions_variable" "automation_app_id" {
  for_each      = local.automation_repos
  repository    = each.value
  variable_name = "AUTOMATION_APP_ID"
  value         = var.github_app_id
}

resource "github_actions_secret" "automation_app_private_key" {
  for_each    = local.automation_repos
  repository  = each.value
  secret_name = "AUTOMATION_APP_PRIVATE_KEY"
  value       = data.aws_ssm_parameter.github_automation_app_key.value
}

# The same key again, in Dependabot's store rather than Actions'.
#
# Two stores exist because a Dependabot-authored `pull_request` event is not
# granted Actions secrets — so a workflow that mints the App token sees
# `vars.AUTOMATION_APP_ID` resolve (variables *are* granted) while
# `secrets.AUTOMATION_APP_PRIVATE_KEY` arrives empty, and
# create-github-app-token fails the run on a required check. That is the whole
# reason a bump PR could sit red on a gate that had nothing to do with the bump.
#
# Mirroring the key here is what makes a token-minting gate work on a bump PR at
# all. It is deliberately not the fix for jobs that had no business running on
# one — a bump PR carries no changelog fragment to number, so that job is
# excluded by author instead, in each repo's changelog-number.yml. Seeding this
# means the next gate that needs the App does not have to relearn any of it.
resource "github_dependabot_secret" "automation_app_private_key" {
  for_each    = local.automation_repos
  repository  = each.value
  secret_name = "AUTOMATION_APP_PRIVATE_KEY"
  value       = data.aws_ssm_parameter.github_automation_app_key.value
}
