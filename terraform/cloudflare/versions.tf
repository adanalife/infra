terraform {
  required_version = ">= 1.8"
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    # used to derive the tunnel_secret for the stage-1 cloudflared tunnel
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1"
    }
  }

  backend "s3" {
    bucket = "adanalife-core-tf-state"
    key    = "cloudflare.tfstate"
  }
}
