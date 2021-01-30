resource "aws_acm_certificate" "primary_static_site" {
  domain_name               = var.domain
  subject_alternative_names = ["static.prod.${var.domain}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}


resource "aws_route53_record" "primary_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.primary_static_site.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = aws_route53_zone.primary.zone_id
}

# resource "aws_acm_certificate" "secondary_static_site" {
#   domain_name               = var.secondary_domain
#   # subject_alternative_names = ["static.prod.${var.secondary_domain}"]
#   validation_method         = "DNS"

#   lifecycle {
#     create_before_destroy = true
#   }
# }
