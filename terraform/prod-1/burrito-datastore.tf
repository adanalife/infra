# Burrito's datastore storage — the bucket holding plan artifacts and run logs.
#
# Not an optional upgrade from the chart's in-memory mock: an apply REPLAYS the
# plan artifact bundle the reviewed plan produced (applyWithoutPlanArtifact
# stays false, which is what makes "what you approved is what runs" true), and
# the mock backend cannot serve one — a manual apply reconciles forever with
# `could not check bundle, there's an issue with the storage backend` and never
# schedules a runner. The mock also loses any in-flight run when the datastore
# restarts, which parks the layer claiming "the last run is still running".
#
# Shape mirrors postgres-backup.tf: a dedicated /bots/ user scoped to this one
# bucket, its key written to an SSM parameter terraform OWNS (so rotation is
# taint-the-key + apply, no hand-seeding), materialized into the
# burrito-datastore-s3 Secret by the ExternalSecret in
# cdk8s/adanalife_k8s/constructs/burrito.py. The datastore is the only reader
# and writer; runners reach it over its own API with a ServiceAccount token,
# never with these credentials.
#
# Artifacts are disposable — regenerating one is an hourly drift plan — so the
# bucket is unversioned and everything expires at 30 days. Burrito prunes its
# TerraformRuns but never the objects behind them.

# KEEP-IN-SYNC with config.burrito.datastore.storage.s3.bucket in
# k8s/burrito/values.yml — the chart takes the name as a plain string.
resource "aws_s3_bucket" "burrito_datastore" {
  bucket = "${local.full_account_name}-burrito-datastore"
}

resource "aws_s3_bucket_public_access_block" "burrito_datastore" {
  bucket                  = aws_s3_bucket.burrito_datastore.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "burrito_datastore" {
  bucket = aws_s3_bucket.burrito_datastore.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "burrito_datastore" {
  bucket = aws_s3_bucket.burrito_datastore.id

  rule {
    id     = "expire-artifacts-30-days"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# --- IAM user + access key ---

resource "aws_iam_user" "burrito_datastore" {
  name = "burrito-datastore"
  path = "/bots/"
  tags = {
    Name = "burrito-datastore"
  }
  force_destroy = false
}

resource "aws_iam_access_key" "burrito_datastore" {
  user = aws_iam_user.burrito_datastore.name
}

# Read AND write, unlike every other burrito identity: this credential reaches
# nothing but the artifact bucket, and the datastore has to serve a stored plan
# back to an apply.
data "aws_iam_policy_document" "burrito_datastore" {
  statement {
    sid = "ReadWriteArtifacts"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
    ]
    resources = [
      "${aws_s3_bucket.burrito_datastore.arn}/*",
    ]
  }

  statement {
    sid       = "ListArtifactBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.burrito_datastore.arn]
  }
}

resource "aws_iam_user_policy" "burrito_datastore" {
  name   = "BurritoDatastoreS3ReadWrite"
  user   = aws_iam_user.burrito_datastore.name
  policy = data.aws_iam_policy_document.burrito_datastore.json
}

# --- SSM parameter (value owned by terraform) ---
# CI read + lifecycle rides secrets.tf's account-wide SSM statements.
resource "aws_ssm_parameter" "burrito_datastore_s3" {
  name        = "/k8s/burrito/datastore-s3-credentials"
  description = "Storage credentials for the Burrito datastore on adanalife-minipc."
  type        = "SecureString"
  value = jsonencode({
    AWS_ACCESS_KEY_ID     = aws_iam_access_key.burrito_datastore.id
    AWS_SECRET_ACCESS_KEY = aws_iam_access_key.burrito_datastore.secret
    AWS_REGION            = var.region
  })
}
