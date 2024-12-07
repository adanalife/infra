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

data "aws_iam_policy_document" "ci" {
  dynamic "statement" {
    # the core account doesnt have a static website bucket
    for_each = local.account_name != "adanalife-core" ? [1] : []
    content {
      sid    = "S3ReadWriteAccess"
      effect = "Allow"

      resources = [
        aws_s3_bucket.static_website.arn,
        "${aws_s3_bucket.static_website.arn}/*",
      ]

      actions = [
        "s3:*Object",
        "s3:ListBucket",
      ]
    }
  }

  statement {
    sid       = "SessionManagement"
    effect    = "Allow"
    resources = ["*"]
    actions   = ["sts:TagSession"]
  }
}

resource "aws_iam_policy" "ci" {
  name   = "AllowAccessForContinuousIntegration"
  policy = data.aws_iam_policy_document.ci.json
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
# IAM Role for CI Terraform
resource "aws_iam_role" "ci_terraform" {
  name               = "CITerraformRole"
  assume_role_policy = data.aws_iam_policy_document.ci_terraform_trust_policy.json
}

# Trust policy for the CI Terraform Role
data "aws_iam_policy_document" "ci_terraform_trust_policy" {
  statement {
    actions = [
      "sts:AssumeRole",
      "sts:TagSession"
    ]

    principals {
      type = "AWS"
      identifiers = [
        # be mindful of who you give access to!
        aws_iam_user.ci.arn
      ]
    }
  }
}

# IAM Policy for CI Terraform Role
# this is expected to be very permissive
#TODO: needs: AccessDenied: User: arn:aws:sts::413585268653:assumed-role/CITerraformRole/GitHubActions is not authorized to perform: s3:PutEncryptionConfiguration on resource: "arn:aws:s3:::static.stage.dana.lol" because no identity-based policy allows the s3:PutEncryptionConfiguration action
#TODO: needs access to terraform state bucket
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

# Attach the policy to the CI Terraform Role
resource "aws_iam_role_policy_attachment" "ci_terraform" {
  role       = aws_iam_role.ci_terraform.name
  policy_arn = aws_iam_policy.ci_terraform.arn
}
variable "managed_iam_policies_for_terraform" {
  description = "List of managed IAM policies to attach to the CI role"
  type        = list(string)
  default = [
    #TODO: remove this at the end and add individual read-only policies
    "ReadOnlyAccess",
    "AmazonS3FullAccess",
    "AmazonEC2FullAccess",
    "IAMFullAccess",
  ]
}

data "aws_iam_policy" "managed_aws_iam_policies" {
  count = length(var.managed_iam_policies_for_terraform)
  name  = var.managed_iam_policies_for_terraform[count.index]
}

resource "aws_iam_role_policy_attachment" "ci_terraform_admin_read_only" {
  count      = length(var.managed_iam_policies_for_terraform)
  role       = aws_iam_role.ci_terraform.name
  policy_arn = data.aws_iam_policy.managed_aws_iam_policies[count.index].arn
}


# add Policy to allow CI User to Assume Terraform Role
resource "aws_iam_policy" "ci_terraform_assume_role" {
  name   = "AllowCIUserToAssumeTerraformRole"
  policy = data.aws_iam_policy_document.ci_terraform_assume_role.json
}

# Attach the assume_role policy to the CI user
resource "aws_iam_user_policy_attachment" "ci_terraform" {
  policy_arn = aws_iam_policy.ci_terraform_assume_role.arn
  user       = aws_iam_user.ci.name
}

# Policy document to allow the CI User to Assume Terraform Role
data "aws_iam_policy_document" "ci_terraform_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    resources = [aws_iam_role.ci_terraform.arn]
  }
}

output "ci_user_access_key" {
  value     = aws_iam_access_key.ci.id
  sensitive = true
}

# the PGP-encrypted secret
output "ci_user_secret" {
  value     = aws_iam_access_key.ci.encrypted_secret
  sensitive = true
}

output "ci_role_arn" {
  value = aws_iam_role.ci.arn
}
