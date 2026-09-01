# Grafana Cloud service accounts, on the provider wired in grafana.tf.
#
# The stack is single-tenant, so service accounts are stack-wide. Tokens are
# returned by the API only at creation time and persisted in tf state
# thereafter — grafana_service_account_token is not importable, and a token
# can only ever live in the state that created it. Read the value out with:
#
#   aws-vault exec adanalife-core --no-session -- \
#     mise exec -- terraform -chdir=terraform/platform output -raw grafana_mcp_token
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
