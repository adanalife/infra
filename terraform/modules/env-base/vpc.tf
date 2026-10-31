# The default VPC that comes pre-installed in every AWS account. It is adopted
# into state only to enable DNS hostnames, set a Name tag, and expose its
# id/cidr_block to rds.tf + outputs — which is the whole of what the native
# aws_default_vpc resource does, so nothing here needs a VPC module.
resource "aws_default_vpc" "default" {
  enable_dns_hostnames = true

  tags = {
    Name = "default"
  }
}

# Keeps state pointing at the same underlying default VPC for any workspace
# still holding the module address. Both sides are aws_default_vpc, so this is
# a state move and never a destroy/create.
moved {
  from = module.default_vpc.aws_default_vpc.this[0]
  to   = aws_default_vpc.default
}
