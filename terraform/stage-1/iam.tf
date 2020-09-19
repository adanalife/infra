# this is the role that Developer users will assume
resource aws_iam_role developer_role {
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
resource aws_iam_role_policy_attachment developer_role {
  policy_arn = aws_iam_policy.developer_role.arn
  role       = aws_iam_role.developer_role.name
}

# let developers browse the AWS console
resource aws_iam_role_policy_attachment basic_web_console_viewing {
  policy_arn = aws_iam_policy.basic_web_console_viewing.arn
  role       = aws_iam_role.developer_role.name
}
