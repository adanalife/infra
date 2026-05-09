# Grafana Cloud metrics-write + logs-write credentials for the
# in-cluster grafana-k8s-monitoring helm chart (Alloy + kube-state-metrics
# + node-exporter + cAdvisor). Separate token from the OTLP creds in
# grafana-cloud.tf so the cluster-monitoring blast radius is isolated
# from the app-side OTel exporters.
#
# Container only (no version resource) — value is populated out-of-band
# and consumed by Alloy at runtime via ESO. Same precedent as
# k8s/obs/twitch-stream-key in secrets.tf: no GetSecretValue grant
# required for CITerraformRole, and a CI compromise can't read the
# token out of state.
#
# Bootstrap (after first `task tf:stage:apply`):
#   aws-vault exec adanalife-stage -- aws secretsmanager put-secret-value \
#     --secret-id k8s/grafana-cloud-metrics-write \
#     --secret-string '{
#       "PROMETHEUS_HOST": "https://prometheus-prod-XX-XXX.grafana.net",
#       "PROMETHEUS_USERNAME": "<numeric prom instance ID>",
#       "LOKI_HOST": "https://logs-prod-XXX.grafana.net",
#       "LOKI_USERNAME": "<numeric loki instance ID>",
#       "TOKEN": "<Grafana Cloud Access Policy token with metrics:write + logs:write>"
#     }'
#
# Endpoints + numeric IDs come from your Grafana Cloud stack's
# `Connections → Add new connection → Hosted Prometheus / Hosted Loki`
# pages. Token is minted via Grafana Cloud admin → Access Policies with
# scopes `metrics:write` + `logs:write`.
#
# The k8s/ name prefix puts this in the AllowESOReadK8sSecrets scope
# (eso.tf), so ESO can read it without an extra IAM grant.

resource "aws_secretsmanager_secret" "k8s_grafana_cloud_metrics_write" {
  name        = "k8s/grafana-cloud-metrics-write"
  description = "Grafana Cloud Mimir/Loki credentials for the in-cluster k8s-monitoring chart. Consumed by Alloy via ESO."

  # Container creation needs CITerraformRole's lifecycle grant attached
  # before AWS will accept CreateSecret on this ARN. Local applies
  # (admin role) don't care, but the ordering is required for a CI
  # bootstrap to succeed without a retry.
  depends_on = [aws_iam_role_policy_attachment.ci_terraform_grafana_metrics_write_manage]
}

# Allow CITerraformRole to manage the lifecycle of the metrics-write
# SM container only (not its value). Same shape as
# ci_terraform_twitch_stream_key_manage in secrets.tf — narrow per-secret
# scope (least privilege). No GetSecretValue, no PutSecretValue: the
# value is owned by the admin who runs `aws secretsmanager
# put-secret-value`, and read by ESO via ESOSecretsReader.
data "aws_iam_policy_document" "ci_terraform_grafana_metrics_write_manage" {
  statement {
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
      "secretsmanager:UpdateSecret",
    ]
    resources = [
      "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:k8s/grafana-cloud-metrics-write-*",
    ]
  }
}

resource "aws_iam_policy" "ci_terraform_grafana_metrics_write_manage" {
  name        = "AllowCITerraformManageStage1GrafanaMetricsWrite"
  description = "Lifecycle access for CITerraformRole to the k8s/grafana-cloud-metrics-write SM secret in stage-1 (container only — value stays out-of-terraform)."
  policy      = data.aws_iam_policy_document.ci_terraform_grafana_metrics_write_manage.json
}

resource "aws_iam_role_policy_attachment" "ci_terraform_grafana_metrics_write_manage" {
  role       = aws_iam_role.ci_terraform.name
  policy_arn = aws_iam_policy.ci_terraform_grafana_metrics_write_manage.arn
}
