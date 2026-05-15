# KEEP-IN-SYNC: terraform/{stage-1,prod-1}/static.tf
#
# De-symlinked 2026-05-11. Stage-1 and prod-1 are intentionally near-identical
# until the modules refactor lands (vault/infra/TODO.md). Any structural
# change here SHOULD be mirrored to the sibling file unless the divergence
# is the whole point of the change.

# adapted from: https://github.com/conortm/terraform-aws-s3-static-website

locals {
  s3_origin_id = "cloudfront-distribution-origin-${local.primary_static_site}.s3.amazonaws.com/${var.static_site_public_dir}"
}

resource "aws_acm_certificate" "primary_static_site" {
  domain_name               = local.primary_static_site
  subject_alternative_names = var.primary_acm_cert_alternative_names
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = local.primary_static_site
  }
}

#TODO: enable reduced redundancy
resource "aws_s3_bucket" "static_website" {
  bucket = local.primary_static_site

}

resource "aws_s3_bucket_website_configuration" "static_website" {
  bucket = aws_s3_bucket.static_website.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "404.html"
  }
}

data "aws_iam_policy_document" "static_website_read_with_secret" {
  statement {
    sid       = "1"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.static_website.arn}/${var.static_site_public_dir}/*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:UserAgent"
      values   = [random_password.static_site_secret.result]
    }
  }
}

resource "aws_s3_bucket_policy" "static_website_read_with_secret" {
  bucket = aws_s3_bucket.static_website.id
  policy = data.aws_iam_policy_document.static_website_read_with_secret.json
}

resource "aws_cloudfront_distribution" "primary_cdn" {
  origin {
    domain_name = aws_s3_bucket_website_configuration.static_website.website_endpoint
    origin_path = "/${var.static_site_public_dir}"
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

  aliases = concat([local.primary_static_site], var.primary_acm_cert_alternative_names)

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

  #TODO: enable cache control
  #cache_control:
  #  'assets/*': public, max-age=86400
  #  #TODO: confirm this works
  #  '*.jpg': public, max-age=86400
  #  '*.png': public, max-age=86400
  #  'favicon.ico': public, max-age=86400
  #  'browserconfig.xml': public, max-age=86400
  #  'robots.txt': public, max-age=86400
  #  'humans.txt': public, max-age=86400
  #  '*': no-cache, no-store

  #TODO: enable redirects
  # redirects:
  #   # I shared this URL with a buncha NERT members
  #   radio: 2017/10/11/san-francisco-emergency-radio-setup
  #   # for convenience
  #   fb: https://www.facebook.com/adanalifeblog
  #   facebook: https://www.facebook.com/adanalifeblog
  #   youtube: https://www.youtube.com/channel/UC8Q7uFC1Xyr2ZnTWOk9Aizg
  #   instagram: https://instagram.com/adanalife_
  #   twitter: https://twitter.com/adanalife_
  #   twitch: https://twitch.tv/adanalife_
  #   # I renamed these articles
  #   2018/03/05/trip-recap-central-coast: 2018/03/05/trip-report-central-coast
  #   2019/01/13/eleven-month-update/: 2019/01/13/post-adventure-summary
  #   # in case people try to change the number and expect it to work
  #   2017/10/01/how-this-site-works-p-2: 2017/10/12/how-this-site-works-p-2
  #   2017/10/12/how-this-site-works-p-1: 2017/10/01/how-this-site-works
  #   # this was posted on my flyer
  #   van-tour: https://youtu.be/_own6DuEpLc
  #   # the stream survey
  #   survey: https://forms.gle/a52NamfEfCcSP7Vc9

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
