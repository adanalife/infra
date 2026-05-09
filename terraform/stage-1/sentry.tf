# Sentry DSNs for the tripbot bot and vlc-server services. Two SM
# secrets, one per Sentry project. Both materialize into k8s Secrets via
# ExternalSecret resources owned by each app's overlay (k8s/apps/*),
# envFrom'd into the respective Deployments as SENTRY_DSN.
#
# Same placeholder-plus-out-of-band pattern as grafana_cloud_otlp:
# terraform owns the container; values are seeded once via
#   aws-vault exec adanalife-stage -- aws secretsmanager put-secret-value \
#     --secret-id k8s/sentry-tripbot \
#     --secret-string '{"SENTRY_DSN":"https://<key>@<org>.ingest.sentry.io/<project>"}'
# and again for k8s/sentry-vlc-server with the matching DSN. ESO picks
# up new values within an hour, or force-sync with
#   kubectl annotate externalsecret sentry --overwrite force-sync=$(date +%s)
# in each app's namespace.
#
# The k8s/ name prefix matches the AllowESOReadK8sSecrets policy in
# eso.tf, so ESO can read both as soon as they're created.

resource "aws_secretsmanager_secret" "sentry_tripbot" {
  name        = "k8s/sentry-tripbot"
  description = "Sentry DSN for the tripbot Go service. Consumed by pkg/errors via SENTRY_DSN env var."
}

resource "aws_secretsmanager_secret_version" "sentry_tripbot" {
  secret_id     = aws_secretsmanager_secret.sentry_tripbot.id
  secret_string = jsonencode({ placeholder = "set via aws secretsmanager put-secret-value" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

resource "aws_secretsmanager_secret" "sentry_vlc_server" {
  name        = "k8s/sentry-vlc-server"
  description = "Sentry DSN for the vlc-server Go service. Consumed by pkg/errors via SENTRY_DSN env var."
}

resource "aws_secretsmanager_secret_version" "sentry_vlc_server" {
  secret_id     = aws_secretsmanager_secret.sentry_vlc_server.id
  secret_string = jsonencode({ placeholder = "set via aws secretsmanager put-secret-value" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
