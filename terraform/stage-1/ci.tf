resource "aws_iam_user" "ci" {
  name = "CIUser"
  path = "/bots/"
  tags = {
    Name = "CIUser"
  }
  force_destroy = false
}

data "aws_iam_policy_document" "ci_service_account_policy" {

  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      identifiers = [
        aws_iam_user.ci.arn
      ]
      type = "AWS"
    }
  }
}

resource "aws_iam_role" "ci" {
  name               = "CIRole"
  assume_role_policy = data.aws_iam_policy_document.ci_service_account_policy.json
}


resource "aws_iam_policy" "ci" {
  name   = "AllowAccessForContinuousIntegration"
  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "S3ReadWriteAccess",
            "Action": [
              "s3:*Object",
              "s3:ListBucket"
            ],
            "Effect": "Allow",
            "Resource": [
                "${aws_s3_bucket.static_website.arn}",
                "${aws_s3_bucket.static_website.arn}/*"
            ]
        }
    ]
}
EOF
}

# give the CI user access to the policy
resource "aws_iam_user_policy_attachment" "ci" {
  policy_arn = aws_iam_policy.ci.arn
  user       = aws_iam_user.ci.name
}

# give the CI role access to the policy
resource "aws_iam_role_policy_attachment" "ci_role_access" {
  role       = aws_iam_role.ci.name
  policy_arn = aws_iam_policy.ci.arn
}

# create an access key so we can use it in k8s
resource "aws_iam_access_key" "ci" {
  user = aws_iam_user.ci.name
  # encrypt it using the @adanalife keybase key
  pgp_key = "keybase:adanalife"
}
