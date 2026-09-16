terraform {
  required_version = ">= 1.8"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket = "adanalife-core-tf-state"
    key    = "prod-1-data.tfstate"
  }
}
