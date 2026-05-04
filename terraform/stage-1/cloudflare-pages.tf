# Cloudflare Pages project for dana.lol static site
#
# Staging-first: this creates "dana-lol-staging" on Cloudflare Pages.
# The site will be available at dana-lol-staging.pages.dev.
# PR preview deployments are automatic for any non-production branch.
#
# TODO: once staging is verified, add a "dana-lol" production project
# alongside this one (in terraform/prod-1/) and update Route53
# www.dana.lol CNAME to point to it.

resource "cloudflare_pages_project" "stage_1" {
  account_id = var.cloudflare_account_id
  name       = var.project_name

  production_branch = var.production_branch

  # Build is handled by GitHub Actions (wrangler pages deploy),
  # not by Cloudflare's built-in CI. No build_config needed.

  source = {
    type = "github"
    config = {
      owner                          = var.github_repo_owner
      repo_name                      = var.github_repo_name
      production_branch              = var.production_branch
      preview_deployment_setting     = "custom"
      preview_branch_includes        = ["*"]
      preview_branch_excludes        = [var.production_branch]
      pr_comments_enabled            = true
      production_deployments_enabled = false
    }
  }
}
