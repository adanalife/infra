terraform {
  required_version = ">= 0.15"
  required_providers {
    # c.p. terraform.io/docs/providers/aws/index.html
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.43"
    }
    # random is used for creating random strings (passwords usually)
    # c.p. terraform.io/docs/providers/random/index.html
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1"
    }
  }

  backend "s3" {
    bucket = "adanalife-core-tf-state"
    key    = "stage-1.tfstate"
  }
}
