resource "aws_acm_certificate" "primary_naked_redirect" {
  domain_name       = var.domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = var.domain
  }
}

resource "aws_route53_record" "primary_naked_redirect" {
  for_each = {
    for dvo in aws_acm_certificate.primary_naked_redirect.domain_validation_options : dvo.domain_name => {
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

resource "aws_cloudfront_distribution" "primary_naked_redirect" {
  origin {
    domain_name = aws_s3_bucket.primary_naked_redirect.website_endpoint
    origin_id   = local.s3_origin_id

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2", "TLSv1.1", "TLSv1"]
    }
  }

  comment         = "CDN for ${aws_s3_bucket.primary_naked_redirect.id} S3 Bucket"
  enabled         = true
  is_ipv6_enabled = true

  aliases = [var.domain]

  default_cache_behavior {
    target_origin_id = local.s3_origin_id
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.primary_naked_redirect.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.1_2016"
  }
}

locals {
  s3_origin_id = "origin-${var.domain}.s3.amazonaws.com"
}
