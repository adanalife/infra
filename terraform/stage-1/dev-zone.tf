# dev.whereisdana.today — Route 53 zone for the "development" k3d cluster
# (adanalife-bees). dev borrows the adanalife-stage AWS account (it has no
# account of its own yet), so its subdomain zone lives here in the stage-1
# workspace rather than a dev-specific one.
#
# Intentionally NOT in the KEEP-IN-SYNC route53.tf / iam.tf / output.tf —
# this is a stage-only resource set (prod-1 has no dev zone), so keeping it
# in its own file keeps those synced files identical to prod-1.
#
# external-dns + cert-manager (DNS-01) for the dev cluster reach this zone
# via the SHARED stage ExternalDNSUser / ExternalDNSRole, granted
# ChangeResourceRecordSets on the dev zone below. A dedicated dev
# external-dns principal is deferred — see vault/infra/TODO.md ("Give dev
# its own external-dns IAM user + role").
#
# Two-phase apply (the zone's nameservers aren't known until first apply):
#   1. apply this workspace  → creates the zone, prints dev_route53_name_servers
#   2. copy those NS into terraform/core/terraform.tfvars
#      (secondary_dev_nameservers) and apply terraform/core to delegate
#      dev.whereisdana.today from the parent whereisdana.today zone.

resource "aws_route53_zone" "dev_subdomain_zone" {
  # secondary_domain is whereisdana.today (primary_domain is dana.lol — the
  # tripbot/vlc/obs hosts live under *.dev.whereisdana.today, matching prod/stage).
  name = "dev.${var.secondary_domain}"
}

# Scope the SHARED external-dns principal's ChangeResourceRecordSets to the
# dev zone. The discovery actions (ListHostedZones / GetChange / etc.) are
# already granted "*" by allow_external_dns_updates on the same user+role,
# so only the zone-scoped write is needed here.
resource "aws_iam_policy" "allow_external_dns_dev_zone" {
  name = "AllowExternalDNSUpdatesDevZone"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "route53:ChangeResourceRecordSets",
        "route53:TestDNSAnswer"
      ],
      "Resource": [
        "arn:aws:route53:::hostedzone/${aws_route53_zone.dev_subdomain_zone.zone_id}"
      ]
    }
  ]
}
EOF
}

# external-dns (k8s) authenticates as the user via its access key.
resource "aws_iam_user_policy_attachment" "external_dns_dev_zone" {
  policy_arn = aws_iam_policy.allow_external_dns_dev_zone.arn
  user       = aws_iam_user.external_dns.name
}

# cert-manager's DNS-01 solver assumes the role.
resource "aws_iam_role_policy_attachment" "external_dns_dev_zone" {
  policy_arn = aws_iam_policy.allow_external_dns_dev_zone.arn
  role       = aws_iam_role.external_dns.name
}

output "dev_route53_name_servers" {
  value = aws_route53_zone.dev_subdomain_zone.name_servers
}

output "dev_route53_zone_id" {
  value = aws_route53_zone.dev_subdomain_zone.zone_id
}
