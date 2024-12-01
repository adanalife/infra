resource "aws_iam_user" "ci" {
  name = "CIUser"
  path = "/bots/"
  tags = {
    Name = "CIUser"
  }
  force_destroy = false
}

# create an access key so we can use it in k8s
resource "aws_iam_access_key" "ci" {
  user = aws_iam_user.ci.name
  # encrypt it using the @adanalife keybase key
  pgp_key = "keybase:adanalife"
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

#TODO: convert this to the data block format
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
        },
        {
            "Sid": "SessionManagement",
            "Action": [
              "sts:TagSession"
            ],
            "Effect": "Allow",
            "Resource": [
                "*"
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


## ci-terraform
# create a special terraform role with extra permissions
resource "aws_iam_role" "ci_terraform" {
  name               = "CITerraformRole"
  #TODO: custom policy here?
  assume_role_policy = data.aws_iam_policy_document.ci_service_account_policy.json
}

resource "aws_iam_policy" "ci_terraform" {
  name   = "AllowAccessForTerraform"
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
                "*"
            ]
        }
    ]
}
EOF
}

# give the CI terraform role access to the terraform policy
resource "aws_iam_role_policy_attachment" "ci_terraform" {
  role       = aws_iam_role.ci_terraform.name
  policy_arn = aws_iam_policy.ci_terraform.arn
}

# this lets the CI user assume role into a CITerraformRole
data "aws_iam_policy_document" "ci_terraform_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [
        aws_iam_role.ci_terraform.arn
      ]
    }
  }
}

# create a new policy with the assume_role permissions
resource "aws_iam_policy" "ci_terraform_assume_role" {
  name   = "AllowCIUserToAssumeTerraformRole"
  policy = data.aws_iam_policy_document.ci_terraform_assume_role.json
}

# attach the assume_role policy to the ci user
resource "aws_iam_user_policy_attachment" "ci_terraform" {
  policy_arn = aws_iam_policy.ci_terraform_assume_role.arn
  user       = aws_iam_user.ci.name
}

# resource "aws_iam_group_policy_attachment" "ci_terraform_assume_role" {
#   group      = var.developer_group
#   policy_arn = aws_iam_policy.ci_terraform_assume_role.arn
#
#   depends_on = [aws_organizations_account.account]
# }
