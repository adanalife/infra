# SSO for the Burrito UI, via Cloudflare Access as the identity provider.
#
# Burrito's built-in basic auth is a server-generated password that nothing
# owns or can rotate, and upstream marks it not-for-production. That was
# tolerable while every credential the UI could reach was read-only; it stops
# being tolerable the moment the UI can trigger an apply, which is why this
# lands before apply support rather than after.
#
# WHY ACCESS AND NOT A NEW IdP: Zero Trust is already the login for guessr's
# admin surface (cloudflare-pages-guessr.tf), with no identity provider
# configured behind it — Access falls back to a one-time PIN mailed to an
# allowlisted address, which is the whole setup for a one-person tool. A SaaS
# application re-uses that as an OIDC provider, so there is no OAuth client to
# register anywhere and no second place identities live.
#
# WHY THIS DOESN'T EXPOSE BURRITO: a SaaS application is Access acting as an
# IdP for someone else's app, not Access proxying traffic to it (that is the
# `self_hosted` type the guessr app uses). Only the browser needs to reach both
# sides, and the browser is on the LAN. Burrito stays LAN/tailnet-only.
#
# Only the LAN redirect URI is registered. Burrito's config takes a single
# redirectUrl, the tailnet path is the degraded one, and naming the tailnet
# domain here would put it in a public repo — the vault docs write it as
# <tailnet> for that reason. Adding it later is a redirect_uris entry sourced
# from SSM, not a redesign.

locals {
  internal_admin_emails = jsondecode(data.aws_ssm_parameter.internal_admin_emails.value)
  burrito_lan_host      = "burrito.prod.whereisdana.today"
}

# Deliberately NOT the guessr admin policy, even though the list is the same
# address today: guessr's is a game-scheduling surface that could reasonably be
# shared with someone one day, and this one gates terraform. Sharing a policy
# would make that a silent grant.
resource "cloudflare_zero_trust_access_policy" "internal_admin" {
  account_id = var.cloudflare_account_id
  name       = "internal tools — allow the admin emails"
  decision   = "allow"

  include = [
    for email in local.internal_admin_emails : {
      email = {
        email = email
      }
    }
  ]

  # Same two-apply bootstrap as the guessr policy, and the same reason: a
  # policy with no include rules is rejected, and the API's error for it says
  # nothing about the parameter behind the list. Let terraform create the
  # parameter empty (it fails here), fill it, apply again:
  #
  #   task tf:prod:apply    # creates the parameter, stops on this precondition
  #   aws-vault exec adanalife-prod -- aws ssm put-parameter --overwrite \
  #     --name /prod-1/internal-admin-emails --type SecureString \
  #     --value '["you@example.com"]'
  #   task tf:prod:apply    # policy + application land
  #
  # Seeding it by hand FIRST is what not to do — put-parameter creates it
  # outside state and the next apply dies on ParameterAlreadyExists.
  lifecycle {
    precondition {
      condition     = length(local.internal_admin_emails) > 0
      error_message = "/prod-1/internal-admin-emails is empty — seed it with a JSON array of addresses, then apply again."
    }
  }
}

resource "cloudflare_zero_trust_access_application" "burrito" {
  account_id           = var.cloudflare_account_id
  name                 = "burrito"
  type                 = "saas"
  session_duration     = "24h"
  app_launcher_visible = false

  policies = [
    {
      id         = cloudflare_zero_trust_access_policy.internal_admin.id
      precedence = 1
    },
  ]

  saas_app = {
    auth_type   = "oidc"
    grant_types = ["authorization_code"]
    # email is what the policy matches on; openid/profile are what burrito
    # needs to establish a session.
    scopes        = ["openid", "email", "profile"]
    redirect_uris = ["https://${local.burrito_lan_host}/auth/callback"]
  }
}

# Terraform owns this value (it comes out of the resource above), so unlike the
# runner credentials there is nothing to seed by hand and no ignore_changes —
# a rotation is an apply. ESO materializes it as
# BURRITO_SERVER_OIDC_CLIENTSECRET, the one OIDC setting the chart takes as an
# env var rather than a value.
resource "aws_ssm_parameter" "burrito_oidc_client_secret" {
  name        = "/k8s/burrito/oidc-client-secret"
  description = "OIDC client secret for the Burrito UI's Cloudflare Access SaaS application. Read by the burrito-server Deployment via ESO."
  type        = "SecureString"
  value       = cloudflare_zero_trust_access_application.burrito.saas_app.client_secret
}

# The client id is the other half burrito needs, and it is not a secret — it
# goes in k8s/burrito/values.yml alongside the issuer, which is built from it:
#
#   https://<team>.cloudflareaccess.com/cdn-cgi/access/sso/oidc/<client_id>
#
# An Access SaaS application serves its discovery document under a
# per-application path, so the client id is part of the issuer rather than a
# separate query. The team domain is deliberately not read here: the
# cloudflare_zero_trust_organization data source needs an Access:Organizations
# read scope the API token does not carry, and the value ends up committed in
# values.yml regardless — Zero Trust -> Settings shows it as
# <team>.cloudflareaccess.com.
output "burrito_oidc_client_id" {
  value = cloudflare_zero_trust_access_application.burrito.saas_app.client_id
}
