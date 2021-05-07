terraform {
  required_version = ">= 0.13"
  required_providers {
    # c.p. terraform.io/docs/providers/aws/index.html
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.39"
    }
    random = {
      source = "hashicorp/random"
    }
  }

  backend "s3" {
    bucket = "adanalife-core-tf-state"
    key    = "prod-1.tfstate"
  }
}
