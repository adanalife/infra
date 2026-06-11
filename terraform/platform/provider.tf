# The platform workspace holds env-agnostic config — things that don't
# belong to any specific "-1" account (GitHub org config today; Grafana
# Cloud is the obvious migration candidate). Nothing env-specific goes here:
# if a resource is owned by stage-1 or prod-1, it belongs in that workspace.
#
# Platform deliberately has no cloud account of its own. The state bucket
# and the few SM containers it needs ride in the org-global core account as
# plumbing — an implementation detail, not an identity. Tasks and CI use the
# adanalife-core credentials for that reason only.
provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}
