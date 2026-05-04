# Cross-state references.
#
# The Cloudflare resources for stage-1 (zone, tunnel, Access app)
# live in terraform/cloudflare/ so they share state with the
# Cloudflare Pages project. We pull a few of their outputs back
# in here for the Route53 NS delegation.
data "terraform_remote_state" "cloudflare" {
  backend = "s3"
  config = {
    bucket = "adanalife-core-tf-state"
    key    = "cloudflare.tfstate"
    region = var.region
  }
}
