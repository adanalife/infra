terraform {
  required_version = ">= 0.15"
  required_providers {
    # c.p. terraform.io/docs/providers/aws/index.html
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.41"
    }
  }

  backend "s3" {
    bucket = "adanalife-core-tf-state"
    key    = "adanalife-core.tfstate"
  }
}
