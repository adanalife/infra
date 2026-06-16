# KEEP-IN-SYNC: terraform/{stage-1,prod-1}/vpc.tf
#
# Stage-1 and prod-1 are intentionally near-identical until they're refactored
# into shared modules. Any structural change here SHOULD be mirrored to the
# sibling file unless the divergence is the whole point of the change.

# this is the VPC that comes pre-installed in every AWS account
module "default_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  create_vpc         = false
  manage_default_vpc = true
  default_vpc_name   = "default"

  default_vpc_enable_dns_hostnames = true
}
