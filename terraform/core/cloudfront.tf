resource aws_acm_certificate dashcam {
  domain_name       = "dashcam.${var.domain}"
  validation_method = "DNS"

  # tags              = {
  #       Environment = "test"
  #         }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "example" {
name = aws_acm_certificate.example.domain_validation_options.resource_record_name
record = aws_acm_certificate.example.domain_validation_options.resource_record_value
type = aws_acm_certificate.example.domain_validation_options.resource_record_type
  # for_each = {
  #   for dvo in aws_acm_certificate.example.domain_validation_options : dvo.domain_name => {
  #     name   = dvo.resource_record_name
  #     record = dvo.resource_record_value
  #     type   = dvo.resource_record_type
  #   }
  # }

  allow_overwrite = true
  name            = aws_acm_certificate.example.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.example.zone_id
}

resource "aws_acm_certificate_validation" "example" {
  certificate_arn         = aws_acm_certificate.example.arn
  validation_record_fqdns = [for record in aws_route53_record.example : record.fqdn]
}









resource aws_cloudfront_distribution dashcam_videos {
  origin {
    domain_name = aws_s3_bucket.dashcam_videos.bucket_regional_domain_name
    origin_id   = aws_s3_bucket.dashcam_videos.id

    # s3_origin_config {
    #   origin_access_identity = "origin-access-identity/cloudfront/ABCDEFG1234567"
    # }
  }

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Dashcam videos"
  default_root_object = "index.html"

  # logging_config {
  #   include_cookies = false
  #   bucket          = "mylogs.s3.amazonaws.com"
  #   prefix          = "myprefix"
  # }

  aliases = [
    "dashcam.${var.domain}"
  ]

  # tailored for immutable content
  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD", "OPTIONS"]
    target_origin_id = aws_s3_bucket.dashcam_videos.id

    forwarded_values {
      query_string = false
      headers      = ["Origin"]

      cookies {
        forward = "none"
      }
    }

    min_ttl                = 0
    default_ttl            = 86400 # maxed this
    max_ttl                = 31536000
    compress               = true
    viewer_protocol_policy = "redirect-to-https"
  }

  # the cheapest price class
  # c.p. https://aws.amazon.com/cloudfront/pricing/
  price_class = "PriceClass_100"

  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["US"]
    }
  }

  # tags = {
  #   Environment = var.environment
  # }

  viewer_certificate {
    acm_certificate_arn = aws_acm_certificate.dashcam.arn
    ssl_support_method  = "sni-only"
    # minimum_protocol_version         = "sni-only"
    # cloudfront_default_certificate = false
  }
}
