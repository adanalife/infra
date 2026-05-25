# Grafana Cloud service accounts managed via the grafana/grafana provider.
#
# Lives in stage-1 because that's where the provider is wired (grafana.tf).
# The Grafana Cloud stack is single-tenant — one stack serves stage-1,
# prod-1, and development — so service accounts created here are stack-wide,
# not env-scoped.
#
# Tokens are returned by the API only at creation time and persisted in tf
# state thereafter. Read out with:
#
#   aws-vault exec adanalife-stage -- task tf:stage:apply -- -target=...
#   terraform -chdir=terraform/stage-1 output -raw grafana_mcp_token
#
# Viewer role grants read on dashboards + query access on datasources,
# which is what the grafana/mcp-grafana server needs to list datasources,
# run PromQL/LogQL against Mimir/Loki, and read dashboard JSON.

resource "grafana_service_account" "claude_code_mcp" {
  name        = "claude-code-mcp"
  role        = "Viewer"
  is_disabled = false
}

resource "grafana_service_account_token" "claude_code_mcp" {
  name               = "claude-code-mcp"
  service_account_id = grafana_service_account.claude_code_mcp.id
}

output "grafana_mcp_token" {
  value     = grafana_service_account_token.claude_code_mcp.key
  sensitive = true
}
