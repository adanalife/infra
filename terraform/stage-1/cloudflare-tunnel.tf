# Cloudflare Tunnel + Access for the local k3d cluster
# (treated as "stage-1" until a real prod cluster exists).
#
# Public ingress flow:
#   user → tripbot.whalecore.com
#        → Cloudflare edge (TLS termination + Access policy)
#        → tunnel → in-cluster cloudflared Deployment
#        → http://tripbot.default.svc.cluster.local:80
#
# Companion stage-1 manifests are at k8s/platform/cloudflared/.
# Operator runbook is in infra/README.md → "exposing services publicly".
#
# Why whalecore.com (and not a subzone of whereisdana.today): Cloudflare
# Free only allows zone creation for root domains. Subdomain zones
# (e.g. apps.stage.whereisdana.today) require Business plan ($200/mo).
# Picking a fresh root domain we already own is the smallest delta.

# Whalecore is the dedicated domain for stage-1 / experimental
# Cloudflare-managed services. Authoritative DNS lives here, not
# Route53 — point whalecore.com's nameservers at the values from
# `terraform output stage_1_zone_name_servers` at your registrar.
resource "cloudflare_zone" "stage_1" {
  account = {
    id = var.cloudflare_account_id
  }
  name = "whalecore.com"
  type = "full"
}

# Allowlisted CIDRs for the Access policy below. Sourced from
# Secrets Manager so the home IP can rotate without a code change.
# Edit via `task update-allowlist`.
locals {
  allowlist_cidrs = jsondecode(data.aws_secretsmanager_secret_version.stage_1_allowlist_cidrs.secret_string)
}

# 32 random bytes used to derive the tunnel token. Rotating this
# requires re-running `task k8s-tunnel-token` then `task k8s-apply-stage-1`.
resource "random_id" "stage_1_tunnel_secret" {
  byte_length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "stage_1" {
  account_id    = var.cloudflare_account_id
  name          = "adanalife-stage-1"
  tunnel_secret = random_id.stage_1_tunnel_secret.b64_std
  config_src    = "cloudflare"
}

# Tunnel ingress — public hostnames map to in-cluster Services.
# tripbot is HTTP-served and the only thing exposed today;
# vlc-server (RTSP), obs (VNC), postgres are not exposed.
#
# Heads-up: cloudflare provider v5.x cannot destroy this resource
# (`terraform plan` shows "Resource Destruction Considerations"
# warning). If you `terraform destroy`, the tunnel-config record
# stays in the API and has to be deleted manually via the dashboard
# or API. Updating it via apply works fine — only destroy is broken.
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "stage_1" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.stage_1.id

  config = {
    ingress = [
      {
        hostname = "tripbot.${cloudflare_zone.stage_1.name}"
        service  = "http://tripbot.default.svc.cluster.local:8080"
      },
      # Catch-all (cloudflared requires this as the last rule).
      {
        service = "http_status:404"
      },
    ]
  }
}

# Orange-cloud CNAME so tripbot.whalecore.com routes into the
# tunnel. Cloudflare proxies and terminates TLS at the edge with an
# auto-issued cert.
resource "cloudflare_dns_record" "stage_1_tripbot_tunnel" {
  zone_id = cloudflare_zone.stage_1.id
  name    = "tripbot"
  type    = "CNAME"
  ttl     = 1 # 1 = auto when proxied
  proxied = true
  content = "${cloudflare_zero_trust_tunnel_cloudflared.stage_1.id}.cfargotunnel.com"
}

# Access app gates tripbot at the edge — traffic only reaches
# the tunnel if the source IP is in local.allowlist_cidrs.
resource "cloudflare_zero_trust_access_application" "stage_1_tripbot" {
  account_id           = var.cloudflare_account_id
  name                 = "tripbot (stage-1)"
  type                 = "self_hosted"
  session_duration     = "24h"
  app_launcher_visible = false

  destinations = [
    {
      type = "public"
      uri  = "tripbot.${cloudflare_zone.stage_1.name}"
    },
  ]

  policies = [
    {
      id         = cloudflare_zero_trust_access_policy.stage_1_tripbot_ip_allow.id
      precedence = 1
    },
  ]
}

resource "cloudflare_zero_trust_access_policy" "stage_1_tripbot_ip_allow" {
  account_id = var.cloudflare_account_id
  name       = "tripbot stage-1 — allow allowlisted IPs"
  # `bypass` (not `allow`): a matching IP skips auth entirely. With
  # `allow`, the include rule only determines who's *eligible* to
  # authenticate via Access — IPs in the allowlist would still get
  # the email-OTP login page. Bypass is the right semantic for
  # "this IP is trusted; let the request through".
  decision = "bypass"

  include = [
    for cidr in local.allowlist_cidrs : {
      ip = {
        ip = cidr
      }
    }
  ]
}

# Tunnel token consumed by the in-cluster cloudflared Deployment.
# Wired to the k8s Secret via `task k8s-tunnel-token`.
data "cloudflare_zero_trust_tunnel_cloudflared_token" "stage_1" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.stage_1.id
}
