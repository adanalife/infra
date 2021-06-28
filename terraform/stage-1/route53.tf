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

