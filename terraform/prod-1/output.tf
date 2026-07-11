# KEEP-IN-SYNC: terraform/{stage-1,prod-1}/output.tf
#
# Re-exports from the env-base module so `terraform output` keeps working
# at the root. Env-specific outputs live next to their resources (eso.tf,
# cloudflare-pages.tf, ...), not here.

output "default_vpc_cidr" {
  description = "The CIDR block of the entire VPC"
  value       = module.env_base.default_vpc_cidr_block
}

output "default_vpc_id" {
  description = "The VPC ID of the default VPC"
  value       = module.env_base.default_vpc_id
}

output "primary_route53_name_servers" {
  value = module.env_base.primary_zone_name_servers
}

output "primary_route53_zone_id" {
  value = module.env_base.primary_zone_id
}

output "secondary_route53_name_servers" {
  value = module.env_base.secondary_zone_name_servers
}

output "secondary_route53_zone_id" {
  value = module.env_base.secondary_zone_id
}

output "rds_tripbot_db_address" {
  value     = module.env_base.tripbot_db_address
  sensitive = true
}

output "external_dns_access_key" {
  value     = module.env_base.external_dns_access_key_id
  sensitive = true
}

# the PGP-encrypted secret
output "external_dns_secret" {
  value     = module.env_base.external_dns_encrypted_secret
  sensitive = true
}

output "external_dns_role_arn" {
  value = module.env_base.external_dns_role_arn
}

output "ci_user_access_key" {
  value     = module.env_base.ci_user_access_key
  sensitive = true
}

# the PGP-encrypted secret
output "ci_user_secret" {
  value     = module.env_base.ci_user_secret
  sensitive = true
}

output "ci_role_arn" {
  value = module.env_base.ci_role_arn
}
