resource "aws_route53_zone" "primary_subdomain_zone" {
  name = local.primary_subdomain
}

resource "aws_route53_zone" "secondary_subdomain_zone" {
  name = local.secondary_subdomain
}

# resource aws_route53_record example {
#   zone_id = aws_route53_zone.secondary_subdomain_zone.zone_id
#   name    = "example.${aws_route53_zone.secondary_subdomain_zone.name}"
#   type    = "CNAME"
#   ttl     = "300"
#   records = ["dana.lol"]
# }

resource "aws_route53_record" "primary_static_site" {
  name    = local.primary_static_site
  type    = "A"
  zone_id = aws_route53_zone.primary_subdomain_zone.zone_id

  alias {
    name                   = aws_cloudfront_distribution.primary_cdn.domain_name
    zone_id                = aws_cloudfront_distribution.primary_cdn.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "tripbot" {
  # only create on prod for now
  count = var.environment == "prod" ? 1 : 0

  zone_id = aws_route53_zone.primary_subdomain_zone.zone_id
  name    = "tripbot.${aws_route53_zone.primary_subdomain_zone.name}"
  type    = "CNAME"
  ttl     = "300"
  records = [aws_instance.tripbot.0.public_dns]
}

# Delegate apps.stage.{secondary} to Cloudflare. Records under
# this subzone (tripbot.apps.stage.whereisdana.today, etc.) are
# managed in terraform/cloudflare/; nameservers come back via
# the cross-state data source in remote-states.tf.
#
# Order of operations on first apply: terraform/cloudflare/ must
# be applied before this, otherwise the remote-state lookup is
# empty.
resource "aws_route53_record" "apps_subdomain_ns" {
  zone_id = aws_route53_zone.secondary_subdomain_zone.zone_id
  name    = "apps.${aws_route53_zone.secondary_subdomain_zone.name}"
  type    = "NS"
  ttl     = 300
  records = data.terraform_remote_state.cloudflare.outputs.apps_stage_name_servers
}
