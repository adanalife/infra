terraform {
  required_version = ">= 1.8"
  required_providers {
    # No provider block here — the resources inherit the default cloudflare
    # provider configured in the calling root, which is where the API token
    # (an SSM lookup, per-account) lives.
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}
