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

# Cloudflare ----------------------------------------------------------

# Tunnel token — sensitive. Wire into the k8s cloudflared Deployment's
# secret with `task k8s-tunnel-token`.
output "cloudflared_tunnel_token" {
  value     = data.cloudflare_zero_trust_tunnel_cloudflared_token.stage_1.token
  sensitive = true
}

# Nameservers Cloudflare assigned to whalecore.com. Point your
# registrar's NS records at these to delegate the zone to Cloudflare.
output "stage_1_zone_name_servers" {
  value       = cloudflare_zone.stage_1.name_servers
  description = "Update whalecore.com NS at the registrar to these"
}

output "pages_url" {
  description = "Cloudflare Pages URL"
  value       = "${var.project_name}.pages.dev"
}

output "pages_project_name" {
  description = "Cloudflare Pages project name (used by wrangler)"
  value       = cloudflare_pages_project.stage_1.name
}
