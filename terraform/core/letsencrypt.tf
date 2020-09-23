# resource tls_private_key primary {
#   algorithm = "RSA"
# }

# resource acme_registration primary {
#   account_key_pem = tls_private_key.primary.private_key_pem
#   email_address   = "${var.email_prefix}acme@${var.email_domain}"
# }

# resource acme_certificate certificate {
#   account_key_pem = acme_registration.primary.account_key_pem
#   common_name     = "dashcam.${var.domain}"
#   # subject_alternative_names = ["www2.${var.domain}"]

#   dns_challenge {
#     provider = "route53"
#     # config = {
#     #   AWS_ACCESS_KEY_ID     = "${var.aws_access_key}"
#     #   AWS_SECRET_ACCESS_KEY = "${var.aws_secret_key}"
#     #   AWS_DEFAULT_REGION    = "us-east-1"
#     # }
#   }
# }
