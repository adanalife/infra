provider aws {
  region = var.region
}

# this lets us get the current account_id
data aws_caller_identity current {}


# set the AWS account alias
resource aws_iam_account_alias alias {
  account_alias = local.account_name
}

# let's encrypt
# https://www.terraform.io/docs/providers/acme/index.html
provider acme {
  server_url = "https://acme-staging-v02.api.letsencrypt.org/directory"
}
