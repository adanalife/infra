# Tunnel token — sensitive. Wire into the k8s cloudflared
# Deployment's secret with `task k8s-tunnel-token`.
output "cloudflared_tunnel_token" {
  value     = data.cloudflare_zero_trust_tunnel_cloudflared_token.stage1.token
  sensitive = true
}

# Nameservers for the apps.stage.whereisdana.today subzone —
# consumed cross-state by terraform/stage-1's Route53 NS
# delegation record.
output "apps_stage_name_servers" {
  value       = cloudflare_zone.apps_stage.name_servers
  description = "Cloudflare nameservers for apps.stage.whereisdana.today (consumed by stage-1 Route53)"
}
