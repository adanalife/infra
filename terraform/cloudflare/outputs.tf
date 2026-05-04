# Tunnel token — sensitive. Wire into the k8s cloudflared
# Deployment's secret with `task k8s-tunnel-token`.
output "cloudflared_tunnel_token" {
  value     = data.cloudflare_zero_trust_tunnel_cloudflared_token.stage_1.token
  sensitive = true
}

# Nameservers Cloudflare assigned to whalecore.com. Point your
# registrar's NS records at these to delegate the zone to Cloudflare.
output "whalecore_name_servers" {
  value       = cloudflare_zone.whalecore.name_servers
  description = "Update whalecore.com NS at the registrar to these"
}
