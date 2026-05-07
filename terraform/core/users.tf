# load in data from json files
locals {
  user_data  = yamldecode(file("user_data.yml"))
  group_data = yamldecode(file("group_data.yml"))
}

# loop over user_data and create the users
resource "aws_iam_user" "user" {
  count = length(local.user_data)
  name  = local.user_data[count.index]["user"]
  tags = merge(
    {
      Name = local.user_data[count.index]["user"]
    },
    lookup(local.user_data[count.index], "tags", {}),
  )
  force_destroy = false
}

# loop over group_data and put developers in Developer group
resource "aws_iam_group_membership" "developers" {
  name  = "developers-group-membership"
  users = local.group_data[aws_iam_group.developer.name]
  group = aws_iam_group.developer.name
}

# loop over group_data and put users in BillingAccess group
resource "aws_iam_group_membership" "billing_access" {
  name  = "billing-access-group-membership"
  users = local.group_data[aws_iam_group.billing_access.name]
  group = aws_iam_group.billing_access.name
}
