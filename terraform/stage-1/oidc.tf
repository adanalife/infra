# OIDC identity provider for GitHub Actions.
#
# Lets workflows in adanalife/* repos federate into AWS without long-lived
# access keys: GitHub mints a short-lived JWT, AWS validates the issuer +
# `sub` claim against role trust policies, and STS returns temporary creds
# via sts:AssumeRoleWithWebIdentity.
#
# This is Phase 1 of retiring the static CI_*_AWS_* secrets. The
# CITerraformRole trust policy is extended (see ci.tf) to accept
# OIDC-federated principals from this provider in addition to the
# existing CIUser principal — purely additive, no workflow changes yet.
resource "aws_iam_openid_connect_provider" "github_actions" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # GitHub's published thumbprint. AWS now also supports an empty list
  # (trust the OIDC discovery doc), but pinning the official thumbprint
  # avoids unnecessary plan churn from AWS-side defaults.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}
