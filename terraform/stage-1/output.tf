# KEEP-IN-SYNC: terraform/{stage-1,prod-1}/output.tf
#
# Stage-1 and prod-1 are intentionally near-identical until they're refactored
# into shared modules. Any structural change here SHOULD be mirrored to the
# sibling file unless the divergence is the whole point of the change.

#TODO: consider adding a message that says something to the effect of:
# visit the website at: https://static.stage.dana.lol/

output "default_vpc_cidr" {
  description = "The CIDR block of the entire VPC"
  value       = aws_default_vpc.default.cidr_block
}

output "default_vpc_id" {
  description = "The VPC ID of the default VPC"
  value       = aws_default_vpc.default.id
}

output "primary_route53_name_servers" {
  value = aws_route53_zone.primary_subdomain_zone.name_servers
}

output "primary_route53_zone_id" {
  value = aws_route53_zone.primary_subdomain_zone.zone_id
}

output "secondary_route53_name_servers" {
  value = aws_route53_zone.secondary_subdomain_zone.name_servers
}

output "secondary_route53_zone_id" {
  value = aws_route53_zone.secondary_subdomain_zone.zone_id
}

output "rds_tripbot_db_address" {
  # hack to allow for empty values
  value     = join("", aws_db_instance.tripbot.*.address)
  sensitive = true
}

output "external_dns_access_key" {
  value     = aws_iam_access_key.external_dns.id
  sensitive = true
}

# the PGP-encrypted secret
output "external_dns_secret" {
  value     = aws_iam_access_key.external_dns.encrypted_secret
  sensitive = true
}

output "external_dns_role_arn" {
  value = aws_iam_role.external_dns.arn
}

# ESO outputs live in eso.tf, Cloudflare outputs live in cloudflare-pages.tf
# and cloudflare-tunnel.tf — non-symlinked files so prod-1 (which symlinks
# this file) doesn't inherit references to resources it doesn't have.
