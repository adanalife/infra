terraform {
  required_version = ">= 1.8"
  required_providers {
    # c.p. terraform.io/docs/providers/aws/index.html
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # random is used for creating random strings (passwords usually)
    # c.p. terraform.io/docs/providers/random/index.html
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    # GCP — manages tripbot-stage (APIs, the delegated terraform SA, WIF).
    # See google.tf; KEEP-IN-SYNC with prod-1's google provider block.
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.35"
    }
  }

  backend "s3" {
    bucket = "adanalife-core-tf-state"
    key    = "stage-1.tfstate"
  }
}
