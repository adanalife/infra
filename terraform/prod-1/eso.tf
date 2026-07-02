# KEEP-IN-SYNC: terraform/{stage-1,prod-1}/eso.tf
#
# External Secrets Operator (ESO) plumbing for prod-1.
#
# In-cluster ESO (k8s/external-secrets/) authenticates to AWS Secrets
# Manager using a dedicated bots/ IAM user (no IRSA on k3d). It then
# reconciles k8s/* secrets in SM into Kubernetes Secrets that consumers
# (cert-manager, external-dns, app workloads) mount.
#
# ESOSecretsReader — IAM user + access key + scoped read policy. Output
# is the (PGP-encrypted) access key. `task k8s:prod:bootstrap-secrets`
# decrypts it via the adanalife keybase team key and pipes the cleartext
# directly into a kubectl-applied Secret — no plaintext secret.env on disk.

# --- ESOSecretsReader: the bootstrap user ESO uses to read SM ---

resource "aws_iam_user" "eso_reader" {
  name = "ESOSecretsReader"
  path = "/bots/"
  tags = {
    Name = "ESOSecretsReader"
  }
  force_destroy = false
}

resource "aws_iam_access_key" "eso_reader" {
  user    = aws_iam_user.eso_reader.name
  pgp_key = "keybase:adanalife"
}

resource "aws_iam_policy" "allow_eso_read_k8s_secrets" {
  name        = "AllowESOReadK8sSecrets"
  description = "Read-only access for in-cluster ESO to k8s/* SM secrets in prod-1."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds",
        ]
        Resource = [
          "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:k8s/*",
        ]
      },
      # SSM Parameter Store analogue (SM → SSM migration, phase 1): same k8s/*
      # read scope. Decryption of SecureString values rides the AWS-managed
      # aws/ssm KMS key, which needs no explicit kms grant.
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
        ]
        Resource = [
          "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/k8s/*",
        ]
      },
    ]
  })
}

resource "aws_iam_user_policy_attachment" "eso_reader" {
  user       = aws_iam_user.eso_reader.name
  policy_arn = aws_iam_policy.allow_eso_read_k8s_secrets.arn
}

# --- ESO bootstrap output ---

# PGP-encrypted secret access key for ESOSecretsReader. Decrypt via
# `terraform output -raw eso_reader_secret | base64 -d | keybase pgp
# decrypt` and feed into `task k8s:prod:bootstrap-secrets`.
output "eso_reader_access_key" {
  value     = aws_iam_access_key.eso_reader.id
  sensitive = true
}

output "eso_reader_secret" {
  value     = aws_iam_access_key.eso_reader.encrypted_secret
  sensitive = true
}
