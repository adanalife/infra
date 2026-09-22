#!/bin/bash
set -euo pipefail

# Warn before the tailscale provider's API token expires.
#
# Tailscale API access tokens cap out at 90 days, and prod-1's terraform
# provider authenticates with one (terraform/prod-1/tailscale.tf explains why
# it can't be an OAuth client: the admin console forces a tag on the auth_keys
# scope, and a tagged client can't then mint the operator's client under
# tag:k8s-operator). When it lapses, EVERY prod-1 plan and apply fails at
# tailscale_acl — CI's plan job, the weekly drift check, Burrito's hourly
# layer, and any local apply. That is how it was found the first time, which is
# the failure this check exists to prevent: not the expiry, the silence.
#
# The token identifies itself: the format is tskey-api-<keyID>-<secret>, so the
# key's own metadata endpoint gives its expiry without needing to list or match
# anything.

THRESHOLD_DAYS="${THRESHOLD_DAYS:-14}"
PARAM="${PARAM:-/prod-1/tailscale-api-key}"

token=$(aws ssm get-parameter --name "$PARAM" --with-decryption \
  --query 'Parameter.Value' --output text)
# Belt and braces for a public repo's logs, where a `set -x` added while
# debugging would otherwise print the credential. Guarded on GITHUB_ACTIONS
# because ::add-mask:: is a runner directive — outside CI it is just an echo,
# which prints the token instead of hiding it.
if [ -n "${GITHUB_ACTIONS:-}" ]; then
  echo "::add-mask::$token"
fi

key_id=$(printf '%s' "$token" | cut -d- -f3)
if [ -z "$key_id" ] || [ "${token#tskey-api-}" = "$token" ]; then
  echo "::error::$PARAM does not hold a tskey-api-… access token." \
    "An auth key (tskey-auth-…) or OAuth secret (tskey-client-…) will not" \
    "authenticate the terraform provider."
  exit 1
fi

# Bearer rather than `curl -u "$token:"`, which both reads as a credential to
# the gitleaks hook and puts the token in the process's argv.
if ! body=$(curl -sf -H "Authorization: Bearer ${token}" \
  "https://api.tailscale.com/api/v2/tailnet/-/keys/${key_id}"); then
  echo "::error::The Tailscale API rejected $PARAM (key ${key_id})." \
    "It has most likely already expired — prod-1 terraform is broken until it" \
    "is rotated. Admin console → Settings → Keys → Generate access token."
  exit 1
fi

expires=$(printf '%s' "$body" | jq -r '.expires // empty')
if [ -z "$expires" ]; then
  echo "Key ${key_id} has no expiry set — nothing to warn about."
  exit 0
fi

# python rather than `date -d`: that flag is GNU-only, and on BSD date it fails
# to an EMPTY string that arithmetic expansion happily reads as zero — so the
# check reports a wildly negative number of days instead of erroring. Silently
# wrong is the one outcome a warning script must not have.
if ! remaining=$(python3 -c '
import datetime, sys
expires = datetime.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
now = datetime.datetime.now(datetime.timezone.utc)
print((expires - now).days)
' "$expires"); then
  echo "::error::Could not parse the expiry timestamp '${expires}'."
  exit 1
fi
echo "Key ${key_id} expires ${expires} (${remaining} days)."

if [ "$remaining" -lt "$THRESHOLD_DAYS" ]; then
  echo "::error::The prod-1 Tailscale API token expires in ${remaining} days" \
    "(${expires}). Rotate it before then or prod-1 terraform stops planning:" \
    "admin console → Settings → Keys → Generate access token, then" \
    "aws-vault exec adanalife-prod -- aws ssm put-parameter --overwrite" \
    "--type SecureString --name ${PARAM} --value 'tskey-api-…'"
  exit 1
fi
