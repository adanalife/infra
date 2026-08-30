# One provider, deliberately. Every provider a workspace declares is a
# credential its Burrito runner has to hold, and the point of this workspace
# is to be the one whose runner holds the least — see README.md.
provider "aws" {
  region = var.region
}
