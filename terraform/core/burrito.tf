# Burrito's in-cluster terraform-plan runner — deliberately READ-ONLY, so the
# credential that lives in the cluster can plan the core workspace but
# structurally cannot apply. Consumed via SM -> ESO (see
# cdk8s/adanalife_k8s/constructs/burrito.py); seeding runbook in
# vault/infra/burrito.md.
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

data "aws_iam_policy" "read_only" {
  name = "ReadOnlyAccess"
}

resource "aws_iam_user_policy_attachment" "burrito_read_only" {
  user       = aws_iam_user.burrito.name
  policy_arn = data.aws_iam_policy.read_only.arn
}

# ReadOnlyAccess includes broad ssm:Get*, and the core workspace reads no SSM
# parameters at all — so deny the runner the account's sensitive SecureStrings
# outright (the platform workspace's GitHub App key). Same load-bearing-Deny
# pattern as the CI grants in stage-1/prod-1 secrets.tf.
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
      "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/platform/*",
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

# ---------------------------------------------------------------------------
# The platform layer's runner — a SECOND, separately-scoped identity
# ---------------------------------------------------------------------------
#
# The platform workspace's github provider auths as the adanalife-automation
# App, whose private key is /platform/github-automation-app-private-key — the
# one parameter the `burrito` user above is explicitly denied. Planning that
# workspace means some in-cluster credential can read that key, so it gets its
# own user rather than widening the one every other layer uses: only the
# platform TerraformLayer's runner pod mounts this credential
# (overrideRunnerSpec.envFrom, cdk8s/adanalife_k8s/constructs/burrito.py), and
# a compromise of any other layer still can't reach the App key.
#
# Still ReadOnlyAccess — this identity can read the key, not apply with it.
resource "aws_iam_user" "burrito_platform" {
  name = "burrito-platform"
  path = "/bots/"
  tags = {
    Name = "burrito-platform"
  }
  force_destroy = false
}

resource "aws_iam_access_key" "burrito_platform" {
  user = aws_iam_user.burrito_platform.name
  # encrypt it using the @adanalife keybase key
  pgp_key = "keybase:adanalife"
}

resource "aws_iam_user_policy_attachment" "burrito_platform_read_only" {
  user       = aws_iam_user.burrito_platform.name
  policy_arn = data.aws_iam_policy.read_only.arn
}

output "burrito_platform_access_key" {
  value     = aws_iam_access_key.burrito_platform.id
  sensitive = true
}

# the PGP-encrypted secret
output "burrito_platform_secret" {
  value     = aws_iam_access_key.burrito_platform.encrypted_secret
  sensitive = true
}
