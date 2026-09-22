# OIDC identity provider for GitHub Actions, so workflows can federate into
# CITerraformRole without long-lived access keys: GitHub mints a short-lived
# JWT, AWS validates the issuer + `sub` claim against the role's trust policy,
# and STS returns temporary credentials via sts:AssumeRoleWithWebIdentity.
#
# This is the AWS counterpart to the keyless GCP path (see google.tf in
# env-base) and the first step toward retiring the static CI_*_AWS_* secrets.
# It is purely additive: the CIUser principal in the trust policy keeps working,
# so nothing has to flip until the workflows are ready.
#
# Opt-in per account via var.github_oidc_subjects — an empty list (the default)
# creates nothing, so enabling stage does not touch core or prod. The provider
# is account-scoped and this module is instantiated once per account, which is
# what keeps it to exactly one provider per account.
resource "aws_iam_openid_connect_provider" "github_actions" {
  count = length(var.github_oidc_subjects) > 0 ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # No thumbprint_list: AWS validates token.actions.githubusercontent.com
  # against its own trusted CA store and ignores any thumbprint supplied for
  # it. Pinning one would only bake in a fingerprint that has already rotated
  # once and that nothing checks.
}
