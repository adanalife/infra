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
    # GCP — prod-only (YouTube provider). Configured in google.tf, credentialed
    # out of AWS SM. Not in stage-1's versions.tf: stage has no GCP resources.
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    # Manages the tailnet ACL + the K8s operator's OAuth client + the node join
    # key (prod-1 only — the tailnet is global; see tailscale.tf).
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.20"
    }
  }

  backend "s3" {
    bucket = "adanalife-core-tf-state"
    key    = "prod-1.tfstate"
  }
}
