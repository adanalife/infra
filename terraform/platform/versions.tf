terraform {
  required_version = ">= 1.8"
  required_providers {
    # c.p. terraform.io/docs/providers/aws/index.html
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # c.p. registry.terraform.io/providers/integrations/github/latest/docs
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }

  # Rides in the core account's state bucket under its own key — platform is
  # a separate workspace, not part of core's state.
  backend "s3" {
    bucket = "adanalife-core-tf-state"
    key    = "adanalife-platform.tfstate"
  }
}
