terraform {
  required_version = ">= 1.8"
  required_providers {
    # c.p. terraform.io/docs/providers/aws/index.html
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.78"
    }
  }

  backend "s3" {
    bucket = "adanalife-core-tf-state"
    key    = "adanalife-core.tfstate"
    # assume_role = {
    #   role_arn = "arn:aws:iam::${local.core_account_id}:role/Terraform"
    # }
  }
}
