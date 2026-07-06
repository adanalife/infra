# S3 bucket + IAM user + access key + SM container for the
# in-cluster postgres backup CronJob on adanalife-minipc.
#
# Shape:
#   - Bucket `adanalife-prod-1-postgres-backups` holds the dumps.
#     Versioning on; public access blocked; SSE-S3. Lifecycle is
#     tiered by prefix written by the CronJob:
#       hourly/  → expire at 2 days
#       daily/   → expire at 30 days
#       weekly/  → transition to Glacier IR at 30 days, kept forever
#       archive/ → no rule; lives forever (genesis / pinned backups)
#   - Dedicated IAM user `PostgresBackupUser` under /bots/ (matching
#     the ExternalDNSUser shape from iam.tf) with PutObject scoped
#     to the bucket. No console access; access key only.
#   - SM container `k8s/postgres/backup-s3-credentials` holds the
#     access key id + secret access key + bucket name + region.
#     Terraform OWNS the value here (same shape as the postgres
#     credentials in secrets.tf) — rotation = taint the access key
#     resource + apply.
#   - ESO in-cluster materializes this into the `postgres-backup-s3`
#     K8s Secret via k8s/apps/postgres/overlays/prod-1/backup-external-secret.yaml.
#
# CI lifecycle grants for this SM container live in secrets.tf
# alongside the other ci_terraform_*_manage blocks (read added to
# the bulk policy, dedicated manage policy with PutSecretValue
# since terraform writes the value).
#
# First-apply note: the IAM access key is brand-new at apply time;
# IAM eventual consistency can take a minute before the first job
# can authenticate. If the first manual run hits AccessDenied,
# wait ~60s and re-run.

resource "aws_s3_bucket" "postgres_backups" {
  bucket = "${local.full_account_name}-postgres-backups"
}

resource "aws_s3_bucket_versioning" "postgres_backups" {
  bucket = aws_s3_bucket.postgres_backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "postgres_backups" {
  bucket                  = aws_s3_bucket.postgres_backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "postgres_backups" {
  bucket = aws_s3_bucket.postgres_backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "postgres_backups" {
  bucket = aws_s3_bucket.postgres_backups.id

  rule {
    id     = "hourly-expire-2-days"
    status = "Enabled"

    filter {
      prefix = "hourly/"
    }

    expiration {
      days = 2
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }

  rule {
    id     = "daily-expire-30-days"
    status = "Enabled"

    filter {
      prefix = "daily/"
    }

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }

  rule {
    id     = "weekly-glacier-keep-forever"
    status = "Enabled"

    filter {
      prefix = "weekly/"
    }

    transition {
      days          = 30
      storage_class = "GLACIER_IR"
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# --- IAM user + access key ---

resource "aws_iam_user" "postgres_backup" {
  name = "PostgresBackupUser"
  path = "/bots/"
  tags = {
    Name = "PostgresBackupUser"
  }
  force_destroy = false
}

resource "aws_iam_access_key" "postgres_backup" {
  user = aws_iam_user.postgres_backup.name
}

data "aws_iam_policy_document" "postgres_backup" {
  statement {
    sid     = "PutBackupObjects"
    actions = ["s3:PutObject", "s3:AbortMultipartUpload"]
    resources = [
      "${aws_s3_bucket.postgres_backups.arn}/*",
    ]
  }

  statement {
    sid       = "ListBackupBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.postgres_backups.arn]
  }
}

resource "aws_iam_user_policy" "postgres_backup" {
  name   = "PostgresBackupS3Writer"
  user   = aws_iam_user.postgres_backup.name
  policy = data.aws_iam_policy_document.postgres_backup.json
}

# --- SSM parameter (value owned by terraform) ---
# ESO materializes it into the postgres-backup-s3 Secret the backup CronJob
# envFroms. CI read/lifecycle rides secrets.tf's account-wide SSM statements.
resource "aws_ssm_parameter" "postgres_backup_s3" {
  name        = "/k8s/postgres/backup-s3-credentials"
  description = "Backup credentials for postgres CronJob on adanalife-minipc."
  type        = "SecureString"
  value = jsonencode({
    AWS_ACCESS_KEY_ID     = aws_iam_access_key.postgres_backup.id
    AWS_SECRET_ACCESS_KEY = aws_iam_access_key.postgres_backup.secret
    AWS_DEFAULT_REGION    = var.region
    S3_BUCKET             = aws_s3_bucket.postgres_backups.bucket
  })
}
