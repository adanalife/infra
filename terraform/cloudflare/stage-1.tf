# Cloudflare Tunnel + Access for the local k3d cluster
# (treated as "stage-1" until a real prod cluster exists).
#
# Public ingress flow:
#   user → tripbot.apps.stage.whereisdana.today
#        → Cloudflare edge (TLS termination + Access policy)
#        → tunnel → in-cluster cloudflared Deployment
#        → http://tripbot.default.svc.cluster.local:80
#
# Companion stage-1 manifests are at k8s/platform/cloudflared/.
# Companion NS delegation in stage-1's Route53 zone is at
# terraform/stage-1/route53.tf (cross-state via remote-states.tf
# there).
#
# Operator runbook is in infra/README.md → "exposing services publicly".

# The new subzone, NS-delegated from stage.whereisdana.today
# (managed in stage-1's Route53 zone). Cloudflare manages
# tripbot.apps.stage.whereisdana.today and any future siblings.
resource "cloudflare_zone" "apps_stage" {
  account = {
    id = var.cloudflare_account_id
  }
  name = "apps.stage.whereisdana.today"
  type = "full"
}

# 32 random bytes used to derive the tunnel token. Rotating this
# requires re-running `task k8s-tunnel-token` then `task k8s-apply-stage1`.
resource "random_id" "stage1_tunnel_secret" {
  byte_length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "stage1" {
  account_id    = var.cloudflare_account_id
  name          = "adanalife-stage1"
  tunnel_secret = random_id.stage1_tunnel_secret.b64_std
  config_src    = "cloudflare"
}

# Tunnel ingress — public hostnames map to in-cluster Services.
# tripbot is HTTP-served and the only thing exposed today;
# vlc-server (RTSP), obs (VNC), postgres are not exposed.
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "stage1" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.stage1.id

  config = {
    ingress = [
      {
        hostname = "tripbot.${cloudflare_zone.apps_stage.name}"
        service  = "http://tripbot.default.svc.cluster.local:80"
      },
      # Catch-all (cloudflared requires this as the last rule).
      {
        service = "http_status:404"
      },
    ]
  }
}

# Orange-cloud CNAME so tripbot.apps.stage.whereisdana.today
# routes into the tunnel. Cloudflare proxies and terminates TLS
# at the edge with an auto-issued cert.
resource "cloudflare_dns_record" "stage1_tripbot_tunnel" {
  zone_id = cloudflare_zone.apps_stage.id
  name    = "tripbot"
  type    = "CNAME"
  ttl     = 1 # 1 = auto when proxied
  proxied = true
  content = "${cloudflare_zero_trust_tunnel_cloudflared.stage1.id}.cfargotunnel.com"
}

# Access app gates tripbot at the edge — traffic only reaches
# the tunnel if the source IP is in var.home_cidrs.
resource "cloudflare_zero_trust_access_application" "stage1_tripbot" {
  account_id           = var.cloudflare_account_id
  name                 = "tripbot (stage-1)"
  type                 = "self_hosted"
  session_duration     = "24h"
  app_launcher_visible = false

  destinations = [
    {
      type = "public"
      uri  = "tripbot.${cloudflare_zone.apps_stage.name}"
    },
  ]

  policies = [
    cloudflare_zero_trust_access_policy.stage1_tripbot_ip_allow.id,
  ]
}

resource "cloudflare_zero_trust_access_policy" "stage1_tripbot_ip_allow" {
  account_id = var.cloudflare_account_id
  name       = "tripbot stage-1 — allow allowlisted IPs"
  decision   = "allow"

  include = [
    for cidr in var.home_cidrs : {
      ip = {
        ip = cidr
      }
    }
  ]
}

# Tunnel token consumed by the in-cluster cloudflared Deployment.
# Wired to the k8s Secret via `task k8s-tunnel-token`.
data "cloudflare_zero_trust_tunnel_cloudflared_token" "stage1" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.stage1.id
}
