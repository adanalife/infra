# Twitch credentials (chat IRC + Helix API) for the tripbot Go service.
# One SM secret holding a JSON blob of the env vars tripbot's
# pkg/twitch/authentication.go requires at boot:
#   TWITCH_CLIENT_ID, TWITCH_CLIENT_SECRET, TWITCH_AUTH_TOKEN
# Materializes into a k8s Secret via an ExternalSecret resource owned by
# k8s/apps/tripbot/overlays/local/, envFrom'd into the Deployment.
#
# Same placeholder-plus-out-of-band pattern as sentry_tripbot:
# terraform owns the container; the real value is seeded once via
#   aws-vault exec adanalife-stage -- aws secretsmanager put-secret-value \
#     --secret-id k8s/tripbot/twitch-creds \
#     --secret-string '{"TWITCH_CLIENT_ID":"...","TWITCH_CLIENT_SECRET":"...","TWITCH_AUTH_TOKEN":"oauth:..."}'
# ESO picks up new values within an hour, or force-sync with
#   kubectl annotate externalsecret tripbot-twitch-creds force-sync=$(date +%s) --overwrite
#
# The k8s/ name prefix matches the AllowESOReadK8sSecrets policy in
# eso.tf, so ESO can read this secret as soon as it's created.

resource "aws_secretsmanager_secret" "tripbot_twitch_creds" {
  name        = "k8s/tripbot/twitch-creds"
  description = "Twitch chat IRC + Helix API credentials for the tripbot Go service. Consumed by pkg/twitch via TWITCH_CLIENT_ID, TWITCH_CLIENT_SECRET, TWITCH_AUTH_TOKEN env vars."
}

resource "aws_secretsmanager_secret_version" "tripbot_twitch_creds" {
  secret_id     = aws_secretsmanager_secret.tripbot_twitch_creds.id
  secret_string = jsonencode({ placeholder = "set via aws secretsmanager put-secret-value" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
