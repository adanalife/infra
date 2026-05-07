terraform {
  required_version = ">= 1.8"
  required_providers {
    # c.p. terraform.io/docs/providers/aws/index.html
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.44"
    }
  }

  backend "s3" {
    bucket = "adanalife-core-tf-state"
    key    = "adanalife-core.tfstate"
  }
}
