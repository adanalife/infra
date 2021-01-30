# adapted from: https://github.com/conortm/terraform-aws-s3-static-website

locals {
  public_dir_with_leading_slash = "${length(var.static_site_public_dir) > 0 ? "/${var.static_site_public_dir}" : ""}"
  s3_origin_id                  = "cloudfront-distribution-origin-${local.primary_static_site}.s3.amazonaws.com${local.public_dir_with_leading_slash}"
  # static_website_routing_rules  = <<EOF
  # [{
  #   "Condition": {
  #       "KeyPrefixEquals": "${var.static_site_public_dir}/${var.static_site_public_dir}/"
  #   },
  #   "Redirect": {
  #       "Protocol": "https",
  #       "HostName": "${local.secondary_static_site}",
  #       "ReplaceKeyPrefixWith": "",
  #       "HttpRedirectCode": "301"
  #   }
  # }]
  # EOF
}

resource "aws_acm_certificate" "primary_static_site" {
  domain_name = var.primary_domain
  subject_alternative_names = [
    "www.${var.primary_domain}",
    local.primary_static_site
  ]
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_s3_bucket" "static_website" {
  bucket = local.primary_static_site

  website {
    index_document = "index.html"
    error_document = "404.html"
  }
}

data "aws_iam_policy_document" "static_website_read_with_secret" {
  statement {
    sid       = "1"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.static_website.arn}${local.public_dir_with_leading_slash}/*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:UserAgent"
      values   = ["${random_password.static_site_secret.result}"]
    }
  }
}

resource "aws_s3_bucket_policy" "static_website_read_with_secret" {
  bucket = aws_s3_bucket.static_website.id
  policy = data.aws_iam_policy_document.static_website_read_with_secret.json
}

resource "aws_cloudfront_distribution" "primary_cdn" {
  origin {
    domain_name = aws_s3_bucket.static_website.website_endpoint
    origin_path = local.public_dir_with_leading_slash
    origin_id   = local.s3_origin_id

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2", "TLSv1.1", "TLSv1"]
    }

    custom_header {
      name  = "User-Agent"
      value = random_password.static_site_secret.result
    }
  }

  comment             = "CDN for ${local.primary_static_site} S3 Bucket"
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  aliases = [
    var.primary_domain,
    "www.${var.primary_domain}",
    local.primary_static_site
  ]

  # custom_error_response {
  #   error_code         = 403
  #   response_page_path = "/error.html"
  #   response_code      = 404
  # }

  # custom_error_response {
  #   error_code         = 404
  #   response_page_path = "/404.html"
  #   response_code      = 404
  # }

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
    acm_certificate_arn      = aws_acm_certificate.primary_static_site.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.1_2016"
  }
}
