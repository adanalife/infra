# KEEP-IN-SYNC: terraform/{stage-1,prod-1}/route53.tf
#
# Stage-1 and prod-1 are intentionally near-identical until they're refactored
# into shared modules. Any structural change here SHOULD be mirrored to the
# sibling file unless the divergence is the whole point of the change.

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
