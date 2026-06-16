# KEEP-IN-SYNC: terraform/{stage-1,prod-1}/iam.tf
#
# Stage-1 and prod-1 are intentionally near-identical until they're refactored
# into shared modules. Any structural change here SHOULD be mirrored to the
# sibling file unless the divergence is the whole point of the change.

# this is the role that Developer users will assume
resource "aws_iam_role" "developer_role" {
  name = "DeveloperUser"

  # allow Developers to stay logged in to AWS console for up to 12hrs
  max_session_duration = 12 * 60 * 60

  # allow users from the core account to assume this role
  assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
      {
          "Action": "sts:AssumeRole",
          "Effect": "Allow",
          "Principal": {
            "AWS": "arn:aws:iam::${var.core_account_id}:root"
          }
      },
      {
          "Action": "sts:AssumeRole",
          "Principal": {
             "Service": "ec2.amazonaws.com"
          },
          "Effect": "Allow"
      }
    ]
}
EOF
}

# attach general developer user access policy
resource "aws_iam_role_policy_attachment" "developer_role" {
  policy_arn = aws_iam_policy.developer_role.arn
  role       = aws_iam_role.developer_role.name
}

# let developers browse the AWS console
resource "aws_iam_role_policy_attachment" "basic_web_console_viewing" {
  policy_arn = aws_iam_policy.basic_web_console_viewing.arn
  role       = aws_iam_role.developer_role.name
}

resource "aws_iam_user" "external_dns" {
  name = "ExternalDNSUser"
  path = "/bots/"
  tags = {
    Name = "ExternalDNSUser"
  }
  force_destroy = false
}

data "aws_iam_policy_document" "external_dns" {

  # allow CIUser and the role itself to assume this role
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      identifiers = [
        aws_iam_user.external_dns.arn,
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.external_dns_role}"
      ]
      type = "AWS"
    }
  }
}

# create an access key so we can use it in k8s
resource "aws_iam_access_key" "external_dns" {
  user = aws_iam_user.external_dns.name
  # encrypt it using the @adanalife keybase key
  pgp_key = "keybase:adanalife"
}

# give the user access to the policy
resource "aws_iam_user_policy_attachment" "external_dns" {
  policy_arn = aws_iam_policy.allow_external_dns_updates.arn
  user       = aws_iam_user.external_dns.name
}

resource "aws_iam_role" "external_dns" {
  name               = var.external_dns_role
  assume_role_policy = data.aws_iam_policy_document.external_dns.json
}

resource "aws_iam_role_policy_attachment" "external_dns" {
  policy_arn = aws_iam_policy.allow_external_dns_updates.arn
  role       = aws_iam_role.external_dns.name
}
