resource aws_route53_zone primary_subdomain_zone {
  name = local.primary_subdomain
}

resource aws_route53_zone secondary_subdomain_zone {
  name = local.secondary_subdomain
}

resource aws_route53_record example {
  zone_id = aws_route53_zone.secondary_subdomain_zone.zone_id
  name    = "example.${aws_route53_zone.secondary_subdomain_zone.name}"
  type    = "CNAME"
  ttl     = "300"
  records = ["dana.lol"]
}
