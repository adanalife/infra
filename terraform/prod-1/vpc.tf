# KEEP-IN-SYNC: terraform/{stage-1,prod-1}/vpc.tf
#
# Stage-1 and prod-1 are intentionally near-identical until they're refactored
# into shared modules. Any structural change here SHOULD be mirrored to the
# sibling file unless the divergence is the whole point of the change.

# The default VPC that comes pre-installed in every AWS account. We only adopt
# it into state to enable DNS hostnames + set a Name tag and expose its
# id/cidr_block to rds.tf + outputs. The native aws_default_vpc resource does
# exactly that in a few lines, so the terraform-aws-modules/vpc module it
# replaced was pure overhead here.
resource "aws_default_vpc" "default" {
  enable_dns_hostnames = true

  tags = {
    Name = "default"
  }
}

# Adopt the VPC previously managed by module.default_vpc without
# destroying/recreating it — same underlying default VPC, same resource type
# (aws_default_vpc), so this is a state move, not a replacement.
#
# Before applying, confirm the source address matches live state:
#   terraform state list | grep default_vpc
# (expected: module.default_vpc.aws_default_vpc.this[0]). Adjust the `from`
# below if your state shows a different internal address, then `terraform plan`
# and confirm it reports a move with NO destroy/create before applying.
moved {
  from = module.default_vpc.aws_default_vpc.this[0]
  to   = aws_default_vpc.default
}
