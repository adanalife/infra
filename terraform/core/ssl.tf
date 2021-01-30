resource "aws_acm_certificate" "secondary_static_site" {
  domain_name = var.secondary_domain
  # subject_alternative_names = [
  #   "www.${var.secondary_domain}"
  # ]
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}


# resource "aws_route53_record" "secondary_cert_validation" {
#   for_each = {
#     for dvo in aws_acm_certificate.secondary_static_site.domain_validation_options : dvo.domain_name => {
#       name   = dvo.resource_record_name
#       record = dvo.resource_record_value
#       type   = dvo.resource_record_type
#     }
#   }

#   allow_overwrite = true
#   name            = each.value.name
#   records         = [each.value.record]
#   ttl             = 60
#   type            = each.value.type
#   zone_id         = aws_route53_zone.secondary.zone_id
#   depends_on      = [aws_acm_certificate.secondary_static_site]
# }
