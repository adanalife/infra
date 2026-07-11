# CI outputs (ci_user_access_key, ci_user_secret, ci_role_arn) live in ci.tf.

output "default_vpc_cidr_block" {
  value = module.default_vpc.default_vpc_cidr_block
}

output "default_vpc_id" {
  value = module.default_vpc.default_vpc_id
}

output "primary_zone_id" {
  value = aws_route53_zone.primary_subdomain_zone.zone_id
}

output "primary_zone_name_servers" {
  value = aws_route53_zone.primary_subdomain_zone.name_servers
}

output "secondary_zone_id" {
  value = aws_route53_zone.secondary_subdomain_zone.zone_id
}

output "secondary_zone_name_servers" {
  value = aws_route53_zone.secondary_subdomain_zone.name_servers
}

output "tripbot_db_address" {
  # hack to allow for empty values
  value     = join("", aws_db_instance.tripbot.*.address)
  sensitive = true
}

output "external_dns_access_key_id" {
  value     = aws_iam_access_key.external_dns.id
  sensitive = true
}

# the PGP-encrypted secret
output "external_dns_encrypted_secret" {
  value     = aws_iam_access_key.external_dns.encrypted_secret
  sensitive = true
}

output "external_dns_role_arn" {
  value = aws_iam_role.external_dns.arn
}

output "external_dns_role_name" {
  value = aws_iam_role.external_dns.name
}

output "external_dns_user_name" {
  value = aws_iam_user.external_dns.name
}

output "ci_terraform_role_name" {
  value = module.ci.ci_terraform_role_name
}
