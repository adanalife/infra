# S3 bucket + IAM user + access key + SSM parameter for CNPG's
# barman-cloud WAL archiving on adanalife-minipc.
#
# Shape (cloned from prod-1/postgres-backup.tf):
#   - Bucket `${local.full_account_name}-postgres-wal` holds WAL segments
#     and base backups. Versioning on; public access blocked; SSE-S3.
#     Barman owns object retention (retentionPolicy on the ObjectStore),
#     so the lifecycle only cleans noncurrent versions and aborted
#     multipart uploads — no expiration rule on current objects.
#   - Dedicated IAM user `PostgresWalUser` under /bots/. Barman needs
#     read + delete (restore and retention enforcement), unlike the
#     write-only dump user.
#   - SSM parameter `/k8s/postgres/wal-s3-credentials`; terraform OWNS
#     the value — rotation = taint the access key resource + apply.
#     ESO materializes it into a K8s Secret for the CNPG ObjectStore.
#     CI read/lifecycle rides secrets.tf's account-wide SSM statements.
#
# First-apply note: the IAM access key is brand-new at apply time;
# IAM eventual consistency can take a minute before the first
# archive command can authenticate.

resource "aws_s3_bucket" "postgres_wal" {
  bucket = "${local.full_account_name}-postgres-wal"
}

resource "aws_s3_bucket_versioning" "postgres_wal" {
  bucket = aws_s3_bucket.postgres_wal.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "postgres_wal" {
  bucket                  = aws_s3_bucket.postgres_wal.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "postgres_wal" {
  bucket = aws_s3_bucket.postgres_wal.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "postgres_wal" {
  bucket = aws_s3_bucket.postgres_wal.id

  rule {
    id     = "cleanup-noncurrent-and-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

# --- IAM user + access key ---

resource "aws_iam_user" "postgres_wal" {
  name = "PostgresWalUser"
  path = "/bots/"
  tags = {
    Name = "PostgresWalUser"
  }
  force_destroy = false
}

resource "aws_iam_access_key" "postgres_wal" {
  user = aws_iam_user.postgres_wal.name
}

data "aws_iam_policy_document" "postgres_wal" {
  statement {
    sid = "ReadWriteWalObjects"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
    ]
    resources = [
      "${aws_s3_bucket.postgres_wal.arn}/*",
    ]
  }

  statement {
    sid       = "ListWalBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.postgres_wal.arn]
  }
}

resource "aws_iam_user_policy" "postgres_wal" {
  name   = "PostgresWalS3ReadWrite"
  user   = aws_iam_user.postgres_wal.name
  policy = data.aws_iam_policy_document.postgres_wal.json
}

# --- SSM parameter (value owned by terraform) ---

resource "aws_ssm_parameter" "postgres_wal_s3" {
  name        = "/k8s/postgres/wal-s3-credentials"
  description = "WAL archive credentials for postgres on adanalife-minipc."
  type        = "SecureString"
  value = jsonencode({
    ACCESS_KEY_ID     = aws_iam_access_key.postgres_wal.id
    SECRET_ACCESS_KEY = aws_iam_access_key.postgres_wal.secret
    REGION            = var.region
    DESTINATION_PATH  = "s3://${aws_s3_bucket.postgres_wal.bucket}/"
  })
}
