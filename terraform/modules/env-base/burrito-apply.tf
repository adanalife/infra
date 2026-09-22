# Burrito's apply identity for this environment — the one credential in the
# cluster that can change anything.
#
# READ THIS BEFORE ADDING A LAYER TO IT. `TerraformLayer.overrideRunnerSpec` is
# per-layer, not per-action: burrito uses the same pod spec, and so the same
# credential, for a plan and for an apply. There is no configuration in which a
# layer plans read-only and applies with write access. So attaching this user
# to a layer means that layer's hourly drift plan also runs as an
# administrator. `core` and `platform` deliberately do not use it — they stay
# on the read-only `burrito` user in burrito.tf, and applying them stays a
# workstation gesture.
#
# WHY ADMINISTRATORACCESS AND NOT SOMETHING SMALLER: an apply of this workspace
# creates and destroys IAM users and roles, Route53 zones, RDS, S3, CloudFront,
# ACM and SSM parameters. Every attempt to enumerate that lands back at "all of
# it", and a policy that merely looks scoped is worse than an honest one — it
# invites the belief that the blast radius is bounded when it isn't. The real
# fix is structural, not a policy document: split the irreplaceable resources
# into their own state and leave that layer read-only. Until then this is an
# admin key living in a cluster, and it should be read that way.
resource "aws_iam_user" "burrito_apply" {
  name = "burrito-apply"
  path = "/bots/"
  tags = {
    Name = "burrito-apply"
  }
  force_destroy = false
}

resource "aws_iam_access_key" "burrito_apply" {
  user = aws_iam_user.burrito_apply.name
  # encrypt it using the @adanalife keybase key
  pgp_key = "keybase:adanalife"
}

data "aws_iam_policy" "burrito_apply_admin" {
  name = "AdministratorAccess"
}

resource "aws_iam_user_policy_attachment" "burrito_apply_admin" {
  user       = aws_iam_user.burrito_apply.name
  policy_arn = data.aws_iam_policy.burrito_apply_admin.arn
}

# The one guardrail that survives an admin attachment, and it is worth keeping:
# an explicit Deny beats an Allow, so these stay unreadable even to this user.
# They are the stream keys and the metrics-write credential — secrets no
# terraform run, plan or apply, has any reason to read.
# KEEP-IN-SYNC with the deny list in burrito.tf and each env's secrets.tf.
data "aws_iam_policy_document" "burrito_apply_deny_sensitive_parameters" {
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

resource "aws_iam_user_policy" "burrito_apply_deny_sensitive_parameters" {
  name   = "DenySensitiveParameterRead"
  user   = aws_iam_user.burrito_apply.name
  policy = data.aws_iam_policy_document.burrito_apply_deny_sensitive_parameters.json
}

output "burrito_apply_access_key" {
  value     = aws_iam_access_key.burrito_apply.id
  sensitive = true
}

# the PGP-encrypted secret
output "burrito_apply_secret" {
  value     = aws_iam_access_key.burrito_apply.encrypted_secret
  sensitive = true
}
