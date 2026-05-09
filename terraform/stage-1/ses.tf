# AWS SES — sending domain + IAM credential + SM container for the
# contact-form k8s deploy.
#
# The contact-form app (adanalife/contact-form, deployed via
# k8s/apps/contact-form/) accepts POSTs from dana.lol and forwards
# them as email to a verified inbox. Path: app → SES SMTP endpoint
# (us-east-1) → recipient.
#
# What's set up here:
#   - SES domain identity for stage.dana.lol, DKIM-verified via three
#     CNAME records published into the existing primary_subdomain
#     Route53 zone (this workspace owns it).
#   - ContactFormMailer IAM user with a single Allow on
#     ses:SendRawEmail scoped to the identity ARN.
#   - SM container at k8s/contact-form/smtp (no version resource —
#     value is owned by `task contact-form:bootstrap-smtp`, populated
#     out-of-band via aws secretsmanager put-secret-value).
#
# Bootstrap (one-time after `task tf:stage:apply`):
#   1. `task contact-form:bootstrap-smtp` — keybase-decrypts the
#      access key, derives the SES SMTP password, writes it to SM.
#      That task also runs `aws ses verify-email-identity` for the
#      recipient address; click the link in the resulting AWS email
#      to complete sandbox verification.
#   2. (Optional, deferred) Request SES production access via the
#      AWS console if EMAIL_RECIPIENTS ever needs to be a non-
#      verified address.
#
# Sandbox: this account starts in SES sandbox, which limits sends to
# verified addresses only. Fine for contact-form (recipient is a
# fixed inbox); revisit if/when prod-1 needs to send to anyone.

resource "aws_ses_domain_identity" "contact_form" {
  domain = local.primary_subdomain
}

resource "aws_ses_domain_dkim" "contact_form" {
  domain = aws_ses_domain_identity.contact_form.domain
}

resource "aws_route53_record" "contact_form_dkim" {
  count   = 3
  zone_id = aws_route53_zone.primary_subdomain_zone.zone_id
  name    = "${aws_ses_domain_dkim.contact_form.dkim_tokens[count.index]}._domainkey.${aws_ses_domain_identity.contact_form.domain}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_ses_domain_dkim.contact_form.dkim_tokens[count.index]}.dkim.amazonses.com"]
}

# --- ContactFormMailer: IAM user the contact-form pod authenticates as ---
#
# Access key ID = SMTP username; SES SMTP password is derived from
# the secret access key by a published HMAC-SHA256 transformation.
# Terraform exposes the derived value via .ses_smtp_password_v4, but
# that attribute is stored plaintext in tf state regardless of
# pgp_key. The bootstrap task ignores it and re-derives the password
# locally from the keybase-decrypted secret, matching the eso_reader
# pattern in eso.tf and avoiding any plaintext-secret consumer of
# the in-state value.

resource "aws_iam_user" "contact_form_mailer" {
  name = "ContactFormMailer"
  path = "/bots/"
  tags = {
    Name = "ContactFormMailer"
  }
  force_destroy = false
}

resource "aws_iam_access_key" "contact_form_mailer" {
  user    = aws_iam_user.contact_form_mailer.name
  pgp_key = "keybase:adanalife"
}

data "aws_iam_policy_document" "contact_form_mailer_send" {
  statement {
    actions   = ["ses:SendRawEmail"]
    resources = [aws_ses_domain_identity.contact_form.arn]
  }
}

resource "aws_iam_user_policy" "contact_form_mailer_send" {
  name   = "ContactFormMailerSendEmail"
  user   = aws_iam_user.contact_form_mailer.name
  policy = data.aws_iam_policy_document.contact_form_mailer_send.json
}

# --- SM container for the SMTP credentials ---
#
# Populated out-of-band by `task contact-form:bootstrap-smtp` which
# writes a JSON blob: {"username":"<access-key-id>","password":"<derived-smtp-password>"}.
# Consumed in-cluster by ESO via the k8s/* read scope on
# ESOSecretsReader (see eso.tf).
#
# Terraform deliberately doesn't manage the secret_version here —
# matches the k8s_obs_twitch_stream_key pattern. Keeps the value
# out of state and out of CI's GetSecretValue grants.
resource "aws_secretsmanager_secret" "k8s_contact_form_smtp" {
  name        = "k8s/contact-form/smtp"
  description = "SES SMTP credentials for the contact-form k8s deploy. Consumed by ESO. JSON: {SMTP_USERNAME, SMTP_PASSWORD} so dataFrom.extract maps directly to envFrom keys. Populate via `task contact-form:bootstrap-smtp`."

  depends_on = [aws_iam_role_policy_attachment.ci_terraform_contact_form_smtp_manage]
}

# --- CITerraformRole policy: lifecycle on the new SM container ---

data "aws_iam_policy_document" "ci_terraform_contact_form_smtp_manage" {
  statement {
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
      "secretsmanager:UpdateSecret",
    ]
    resources = [
      "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:k8s/contact-form/smtp-*",
    ]
  }
}

resource "aws_iam_policy" "ci_terraform_contact_form_smtp_manage" {
  name        = "AllowCITerraformManageStage1ContactFormSMTP"
  description = "Lifecycle access for CITerraformRole to the k8s/contact-form/smtp SM secret in stage-1 (container only — value stays placeholder via out-of-band put-secret-value)."
  policy      = data.aws_iam_policy_document.ci_terraform_contact_form_smtp_manage.json
}

resource "aws_iam_role_policy_attachment" "ci_terraform_contact_form_smtp_manage" {
  role       = aws_iam_role.ci_terraform.name
  policy_arn = aws_iam_policy.ci_terraform_contact_form_smtp_manage.arn
}

# --- Bootstrap outputs ---
#
# Decrypt via:
#   terraform output -raw contact_form_mailer_secret_encrypted | base64 -d | keybase pgp decrypt
# Exposed by `task contact-form:bootstrap-smtp` automatically.
#
# Lives here (not in output.tf) because output.tf is symlinked from
# prod-1, which has no ses.tf and would fail to validate.

output "contact_form_mailer_access_key" {
  value     = aws_iam_access_key.contact_form_mailer.id
  sensitive = true
}

output "contact_form_mailer_secret_encrypted" {
  value     = aws_iam_access_key.contact_form_mailer.encrypted_secret
  sensitive = true
}
