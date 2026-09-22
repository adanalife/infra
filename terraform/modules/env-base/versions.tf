terraform {
  required_version = ">= 1.8"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8"
    }
    # No provider block here — google.tf's resources inherit the default
    # google provider configured in the calling root.
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }
}
