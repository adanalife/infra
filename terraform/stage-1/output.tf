#TODO: consider adding a message that says something to the effect of:
# visit the website at: https://static.stage.dana.lol/

output "default_vpc_cidr" {
  description = "The CIDR block of the entire VPC"
  value       = module.default_vpc.default_vpc_cidr_block
}

output "default_vpc_id" {
  description = "The VPC ID of the default VPC"
  value       = module.default_vpc.default_vpc_id
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
  value = join("", aws_db_instance.tripbot.*.address)
}

output "external_dns_access_key" {
  value = aws_iam_access_key.external_dns.id
  sensitive = true
}

# the PGP-encrypted secret
output "external_dns_secret" {
  value = aws_iam_access_key.external_dns.encrypted_secret
  sensitive = true
}

output "external_dns_role_arn" {
  value = aws_iam_role.external_dns.arn
}

output "ci_user_access_key" {
  value = aws_iam_access_key.ci.id
  sensitive = true
}

# the PGP-encrypted secret
output "ci_user_secret" {
  value = aws_iam_access_key.ci.encrypted_secret
  sensitive = true
}

output "ci_role_arn" {
  value = aws_iam_role.ci.arn
}
