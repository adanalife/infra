# Grafana Cloud service accounts managed via the grafana/grafana provider.
#
# The rest of the Grafana Cloud stack lives in terraform/platform (the stack
# is single-tenant and env-agnostic); the service account + token below are
# the one straggler still in this workspace, because the token's key exists
# only in this state — grafana_service_account_token is not importable and
# its key is returned by the API only at creation time. Moving it means
# minting a replacement token from the platform workspace, not a state move.
# Until then this root keeps its own provider config, sharing the stage
# credential parameter.
#
# Read the token out with:
#
#   aws-vault exec adanalife-stage -- task tf:stage:apply -- -target=...
#   terraform -chdir=terraform/stage-1 output -raw grafana_mcp_token
#
# Viewer role grants read on dashboards + query access on datasources,
# which is what the grafana/mcp-grafana server needs to list datasources,
# run PromQL/LogQL against Mimir/Loki, and read dashboard JSON.

# The credential data source stays declared in secrets.tf with the rest.
locals {
  grafana_creds = jsondecode(data.aws_ssm_parameter.grafana_cloud_api.value)
}

provider "grafana" {
  url  = lookup(local.grafana_creds, "GRAFANA_CLOUD_URL", "https://placeholder.grafana.net")
  auth = lookup(local.grafana_creds, "GRAFANA_CLOUD_API_TOKEN", "placeholder")
}

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
