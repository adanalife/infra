# Burrito's in-cluster terraform-plan runner, per environment — the env-account
# twin of the core-account user in terraform/core/burrito.tf. Deliberately
# READ-ONLY: the credential that lives in the cluster can plan this workspace
# but structurally cannot apply. Consumed via SM -> ESO (see
# cdk8s/adanalife_k8s/constructs/burrito.py); the key is seeded by hand from the
# PGP-encrypted outputs below.
#
# ReadOnlyAccess is what makes the cloudflare / grafana / tailscale providers
# work without seeding any new tokens: they read their credentials from this
# account's Parameter Store, so the runner picks them up the same way a CI plan
# does. The GCP provider is the one that can't ride on this — it authenticates
# keyless via the cluster's own OIDC issuer (google.tf).
resource "aws_iam_user" "burrito" {
  name = "burrito"
  path = "/bots/"
  tags = {
    Name = "burrito"
  }
  force_destroy = false
}

resource "aws_iam_access_key" "burrito" {
  user = aws_iam_user.burrito.name
  # encrypt it using the @adanalife keybase key
  pgp_key = "keybase:adanalife"
}

data "aws_iam_policy" "burrito_read_only" {
  name = "ReadOnlyAccess"
}

resource "aws_iam_user_policy_attachment" "burrito_read_only" {
  user       = aws_iam_user.burrito.name
  policy_arn = data.aws_iam_policy.burrito_read_only.arn
}

# The same load-bearing Deny the CI role carries (each env's secrets.tf,
# SSMDenySensitiveParameterRead): ReadOnlyAccess includes broad ssm:Get*, and
# these parameters are secrets no terraform plan needs to read.
# KEEP-IN-SYNC with the deny list in terraform/{stage-1,prod-1}/secrets.tf.
data "aws_iam_policy_document" "burrito_deny_sensitive_parameters" {
  statement {
    sid    = "SSMDenySensitiveParameterRead"
    effect = "Deny"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "ssm:GetParameterHistory",
    ]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/k8s/obs/*",
      "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/k8s/grafana-cloud-metrics-write",
    ]
  }
}

resource "aws_iam_user_policy" "burrito_deny_sensitive_parameters" {
  name   = "DenySensitiveParameterRead"
  user   = aws_iam_user.burrito.name
  policy = data.aws_iam_policy_document.burrito_deny_sensitive_parameters.json
}

output "burrito_access_key" {
  value     = aws_iam_access_key.burrito.id
  sensitive = true
}

# the PGP-encrypted secret
output "burrito_secret" {
  value     = aws_iam_access_key.burrito.encrypted_secret
  sensitive = true
}
