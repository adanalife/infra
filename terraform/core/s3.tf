resource aws_s3_bucket dashcam_videos {
  bucket = "${local.account_name}-dashcam-videos"
  acl    = "private"

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }

  website {
    error_document = "error.html"
    index_document = "index.html"
  }

  tags = {
    Name = "${local.account_name}-dashcam-videos"
  }
}

# prevent this bucket from ever going public
resource aws_s3_bucket_public_access_block dashcam_videos {
  bucket = aws_s3_bucket.dashcam_videos.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# an empty S3 bucket that serves as a redirect
resource aws_s3_bucket primary_redirect {
  bucket = "${var.domain}-test"
  acl    = "private"

  website {
    error_document = "error.html"
    index_document = "index.html"

    routing_rules = <<EOF
[{
    "Redirect": {
        "Protocol": "https",
        "HostName": "www.dana.lol",
        "HttpRedirectCode": "301"
    }
}]
EOF
  }

  tags = {
    Name = "${var.domain}-test"
  }
}

# an empty S3 bucket that serves as a redirect
resource aws_s3_bucket secondary_redirect {
  bucket = "${var.secondary_domain}-test"
  acl    = "private"

  website {
    error_document = "error.html"
    index_document = "index.html"

    routing_rules = <<EOF
[{
    "Redirect": {
        "Protocol": "https",
        "HostName": "www.twitch.tv",
        "ReplaceKeyPrefixWith": "ADanaLife_",
        "HttpRedirectCode": "301"
    }
}]
EOF
  }

  tags = {
    Name = "${var.secondary_domain}-test"
  }
}
