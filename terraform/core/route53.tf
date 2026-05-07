# manage the dana.lol domain
resource "aws_route53_zone" "primary" {
  name = var.domain
}

# manage the whereisdana.today domain
resource "aws_route53_zone" "secondary" {
  name = var.secondary_domain
}

# use the prod nameservers so prod can manage its own routes
resource "aws_route53_record" "primary_prod_nameservers" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "prod.${aws_route53_zone.primary.name}"
  type    = "NS"
  ttl     = "30"

  records = var.primary_prod_nameservers
}

# use the prod nameservers so prod can manage its own routes
resource "aws_route53_record" "secondary_prod_nameservers" {
  zone_id = aws_route53_zone.secondary.zone_id
  name    = "prod.${aws_route53_zone.secondary.name}"
  type    = "NS"
  ttl     = "30"

  records = var.secondary_prod_nameservers
}

# use the stage nameservers so stage can manage its own routes
resource "aws_route53_record" "primary_stage_nameservers" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "stage.${aws_route53_zone.primary.name}"
  type    = "NS"
  ttl     = "30"

  records = var.primary_stage_nameservers
}

# use the stage nameservers so stage can manage its own routes
resource "aws_route53_record" "secondary_stage_nameservers" {
  zone_id = aws_route53_zone.secondary.zone_id
  name    = "stage.${aws_route53_zone.secondary.name}"
  type    = "NS"
  ttl     = "30"

  records = var.secondary_stage_nameservers
}

resource "aws_route53_record" "primary_naked" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = var.domain
  type    = "A"

  # https://docs.aws.amazon.com/general/latest/gr/s3.html#s3_website_region_endpoints
  # alias {
  #   name                   = "s3-website-us-east-1.amazonaws.com."
  #   zone_id                = "Z3AQBSTGFYJSTF" # us-east-1
  #   evaluate_target_health = false
  # }
  alias {
    name                   = aws_cloudfront_distribution.primary_naked_redirect.domain_name
    zone_id                = aws_cloudfront_distribution.primary_naked_redirect.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "primary_naked_acm_cert_validation" {
  name    = var.primary_naked_acm_dns_name
  records = [var.primary_naked_acm_dns_record]
  ttl     = 60
  type    = var.primary_naked_acm_dns_type
  zone_id = aws_route53_zone.primary.zone_id
}

resource "aws_route53_record" "secondary_naked" {
  zone_id = aws_route53_zone.secondary.zone_id
  name    = var.secondary_domain
  type    = "A"

  # https://docs.aws.amazon.com/general/latest/gr/s3.html#s3_website_region_endpoints
  alias {
    name                   = "s3-website-us-east-1.amazonaws.com."
    zone_id                = "Z3AQBSTGFYJSTF" # us-east-1
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "primary_www" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "www.${var.domain}"
  type    = "CNAME"
  # Low TTL during cutover so rollback is fast. Bump back to 300 once
  # CF Pages traffic has been stable for ~24h.
  ttl     = "60"
  records = ["dana-lol-production.pages.dev"]
}

resource "aws_route53_record" "secondary_www" {
  zone_id = aws_route53_zone.secondary.zone_id
  name    = "www.${var.secondary_domain}"
  type    = "CNAME"
  ttl     = "300"
  records = ["static.prod.${var.secondary_domain}"]
}

resource "aws_route53_record" "primary_staging" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "staging.${var.domain}"
  type    = "CNAME"
  ttl     = "300"
  records = ["static.stage.${var.domain}"]
}

resource "aws_route53_record" "secondary_staging" {
  zone_id = aws_route53_zone.secondary.zone_id
  name    = "staging.${var.secondary_domain}"
  type    = "CNAME"
  ttl     = "300"
  records = ["static.stage.${var.secondary_domain}"]
}

resource "aws_route53_record" "primary_www_acm_cert_validation" {
  name    = var.primary_www_acm_dns_name
  records = [var.primary_www_acm_dns_record]
  ttl     = 60
  type    = var.primary_www_acm_dns_type
  zone_id = aws_route53_zone.primary.zone_id
}


resource "aws_route53_record" "status" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = var.status_domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.status_redirect.domain_name
    zone_id                = aws_cloudfront_distribution.status_redirect.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "keybase" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "_keybase.${var.domain}"
  type    = "TXT"
  ttl     = "300"
  records = ["keybase-site-verification=4c5lF70z6Zp4jBKt7lDhS9PT-fJ5xFTip_2H_qBkZ1c"]
}

# for verifying Brave browser
resource "aws_route53_record" "brave" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = var.domain
  type    = "TXT"
  ttl     = "300"
  records = ["brave-ledger-verification=9422ad35f6a8d886d6636c1ef09d84e950b5c1bf2ab28d28f00d0acc613aac79"]
}

resource "aws_route53_record" "develop" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "develop.${var.domain}"
  type    = "CNAME"
  ttl     = "300"
  records = ["localhost"]
}

# this is just a friendly alias to make SSH easier
#TODO: update stream server to set this programatically
# stream.local.whereisdana.today
resource "aws_route53_record" "stream_local" {
  zone_id = aws_route53_zone.secondary.zone_id
  name    = "stream.local.${var.secondary_domain}"
  type    = "A"
  ttl     = "300"
  records = ["10.111.253.168"]
}

resource "aws_route53_record" "tripbot" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "tripbot.${var.domain}"
  type    = "CNAME"
  ttl     = "300"
  records = ["tripbot.prod.${var.domain}"]
}

resource "aws_route53_record" "hawthorne" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "hawthorne.${var.domain}"
  type    = "A"
  ttl     = "300"
  records = ["68.239.30.152"]
}

resource "aws_route53_record" "certbot" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "_acme-challenge.${var.domain}"
  type    = "TXT"
  ttl     = "300"
  records = ["3DnnRt02WD645OYeOEAuR2cw7--WiWT3YSP_RMlaNu0"]
}

resource "aws_route53_record" "bluesky_verification" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "_atproto.${var.domain}"
  type    = "TXT"
  ttl     = "300"
  records = ["did=did:plc:3eikvksr7ojyaywda47uz5t7"]
}

#TODO: is this being used anywhere?
# resource aws_route53_record twitch_scripts {
#   zone_id = aws_route53_zone.primary.zone_id
#   name    = "twitch-scripts.${var.domain}"
#   type    = "A"
#   ttl     = "300"
#   records = ["172.3.109.123"]
# }
