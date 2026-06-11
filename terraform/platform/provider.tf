# The platform workspace holds config that spans environments (GitHub org
# config; candidates to migrate in: Grafana Cloud, anything else that isn't
# owned by exactly one env). Its AWS resources (SM containers, CI grants)
# live in the CORE account — the org-global one — so tasks and CI use the
# adanalife-core credentials.
provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}
