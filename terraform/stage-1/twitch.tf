# Twitch credentials (Helix API + OAuth Authorization Code flow) for the
# tripbot Go service. One SM secret holding a JSON blob of the env vars
# tripbot's pkg/twitch/authentication.go requires at boot:
#   TWITCH_CLIENT_ID, TWITCH_CLIENT_SECRET
# The IRC token is no longer an env var — since tripbot v2.3.0 it lives
# in the oauth_tokens DB table, populated by `task auth:bootstrap` and
# rotated hourly via the pg_try_advisory_lock-fenced refresh cron.
#
# Materializes into a k8s Secret via an ExternalSecret resource owned by
# k8s/apps/tripbot/overlays/local/, envFrom'd into the Deployment.
#
# Same placeholder-plus-out-of-band pattern as sentry_tripbot:
# terraform owns the container; the real value is seeded once via
#   aws-vault exec adanalife-stage -- aws secretsmanager put-secret-value \
#     --secret-id k8s/tripbot/twitch-creds \
#     --secret-string '{"TWITCH_CLIENT_ID":"...","TWITCH_CLIENT_SECRET":"..."}'
# ESO picks up new values within an hour, or force-sync with
#   kubectl annotate externalsecret tripbot-twitch-creds force-sync=$(date +%s) --overwrite
#
# The k8s/ name prefix matches the AllowESOReadK8sSecrets policy in
# eso.tf, so ESO can read this secret as soon as it's created.

resource "aws_secretsmanager_secret" "tripbot_twitch_creds" {
  name        = "k8s/tripbot/twitch-creds"
  description = "Twitch app credentials for tripbot. App: tripbot-development. Keys: TWITCH_CLIENT_ID, TWITCH_CLIENT_SECRET. Consumed by pkg/twitch (Helix API + OAuth Authorization Code flow). IRC token lives in the oauth_tokens DB table, not in this secret."
}

resource "aws_secretsmanager_secret_version" "tripbot_twitch_creds" {
  secret_id     = aws_secretsmanager_secret.tripbot_twitch_creds.id
  secret_string = jsonencode({ placeholder = "set via aws secretsmanager put-secret-value" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
