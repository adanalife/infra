# GitHub org config, managed through the adanalife-automation GitHub App.
#
# The provider auths AS the App (no PAT anywhere): the App's private key
# lives in Parameter Store (/platform/github-automation-app-private-key,
# seeded out-of-band per secrets.tf), and the App ID / installation ID are
# plain config in terraform.tfvars.
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
# Consumers: release-please.yml in every release repo — as an ordinary actor
# the App gets the release PR's checks run unheld (github-actions[bot] parks
# them at action_required) and its tag fires release.yml without an explicit
# dispatch — plus changelog-number.yml, pr-gates.yml and platforms-contract.yml
# where they exist, and infra's cdk8s-synth.yml for auto-synth push-back.

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
    "playout",
    "platform-gateway",
    "website",
    "video-pipeline",
    "guessr",
    "flare",
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

# Dependabot keeps a secret store of its own, and nothing here writes to it.
#
# Worth knowing before adding it back: a Dependabot-authored `pull_request` event
# is granted Actions *variables* but not Actions *secrets*, so a workflow minting
# the App token on such a PR sees `vars.AUTOMATION_APP_ID` resolve while
# `secrets.AUTOMATION_APP_PRIVATE_KEY` arrives empty and the mint step fails.
# Mirroring the key into Dependabot's store is the fix for a gate that genuinely
# needs the App on a bump PR — and it costs the App a `dependabot_secrets`
# permission it does not have (the installation carries actions, actions_variables,
# contents, metadata, pull_requests, secrets), which means an org-level approval of
# the permission change, not just a terraform edit.
#
# No gate needs it today. The jobs that were failing had no business running on a
# bump PR at all — a bump carries no changelog fragment to number, and cannot move
# a contract file synced from a sibling repo — so each is excluded by author in its
# own workflow instead. That keeps the App key out of Dependabot-triggered runs.
