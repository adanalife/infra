resource "aws_s3_bucket" "dashcam_videos" {
  bucket = "${local.account_name}-dashcam-videos"

  tags = {
    Name = "${local.account_name}-dashcam-videos"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "dashcam_videos" {
  bucket = aws_s3_bucket.dashcam_videos.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_website_configuration" "dashcam_videos" {
  bucket = aws_s3_bucket.dashcam_videos.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }
}

# prevent this bucket from ever going public
resource "aws_s3_bucket_public_access_block" "dashcam_videos" {
  bucket = aws_s3_bucket.dashcam_videos.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# an empty S3 bucket that serves as a redirect
resource "aws_s3_bucket" "primary_naked_redirect" {
  bucket = var.domain

  tags = {
    Name = var.domain
  }
}

resource "aws_s3_bucket_website_configuration" "primary_naked_redirect" {
  bucket = aws_s3_bucket.primary_naked_redirect.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }

  routing_rule {
    redirect {
      protocol           = "https"
      host_name          = "www.dana.lol"
      http_redirect_code = "301"
    }
  }
}

# an empty S3 bucket that serves as a redirect
resource "aws_s3_bucket" "secondary_naked_redirect" {
  bucket = var.secondary_domain

  tags = {
    Name = var.secondary_domain
  }
}

resource "aws_s3_bucket_website_configuration" "secondary_naked_redirect" {
  bucket = aws_s3_bucket.secondary_naked_redirect.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }

  routing_rule {
    redirect {
      protocol                = "https"
      host_name               = "www.twitch.tv"
      replace_key_prefix_with = "ADanaLife_"
      http_redirect_code      = "301"
    }
  }
}

# an empty S3 bucket that serves as a redirect
resource "aws_s3_bucket" "status_redirect" {
  bucket = var.status_domain

  tags = {
    Name = var.status_domain
  }
}

resource "aws_s3_bucket_website_configuration" "status_redirect" {
  bucket = aws_s3_bucket.status_redirect.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }

  routing_rule {
    redirect {
      protocol           = "https"
      host_name          = "stats.uptimerobot.com"
      replace_key_with   = var.uptimerobot_path
      http_redirect_code = "301"
    }
  }
}

resource "aws_glacier_vault" "dashcam" {
  name = "Dashcam"

  tags = {
    Name = "Dashcam"
  }
}
