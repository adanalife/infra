terraform {
  required_version = ">= 1.8"
  required_providers {
    # c.p. terraform.io/docs/providers/aws/index.html
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.78"
    }
    # random is used for creating random strings (passwords usually)
    # c.p. terraform.io/docs/providers/random/index.html
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket = "adanalife-core-tf-state"
    key    = "prod-1.tfstate"
  }
}
