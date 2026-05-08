# Grafana Cloud OTLP credentials for in-cluster OpenTelemetry exporters
# (tripbot, vlc-server). Follows the placeholder-plus-out-of-band pattern:
# terraform owns the SM container; the real value is set once via
# `aws-vault exec adanalife-stage -- aws secretsmanager put-secret-value
#   --secret-id k8s/grafana-cloud-otlp \
#   --secret-string '{"OTEL_EXPORTER_OTLP_ENDPOINT":"https://otlp-gateway-prod-us-central-0.grafana.net/otlp","OTEL_EXPORTER_OTLP_HEADERS":"Authorization=Basic <base64(instanceID:apiKey)>"}'`
# (replace endpoint with whatever Grafana Cloud's OTLP gateway shows for
# this stack). ESO picks up the new value within an hour, or force-sync
# with `kubectl annotate externalsecret grafana-cloud-otlp force-sync=$(date +%s) --overwrite`.
#
# The k8s/ name prefix matches the AllowESOReadK8sSecrets policy in
# eso.tf, so no additional IAM grants are needed — ESO can already read
# this secret as soon as it's created.

resource "aws_secretsmanager_secret" "grafana_cloud_otlp" {
  name        = "k8s/grafana-cloud-otlp"
  description = "Grafana Cloud OTLP endpoint + bearer auth for in-cluster OTel exporters."
}

resource "aws_secretsmanager_secret_version" "grafana_cloud_otlp" {
  secret_id     = aws_secretsmanager_secret.grafana_cloud_otlp.id
  secret_string = jsonencode({ placeholder = "set via aws secretsmanager put-secret-value" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
