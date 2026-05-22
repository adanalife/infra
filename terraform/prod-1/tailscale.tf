# ============================================================================
# Tailscale — tailnet policy + the Kubernetes operator's credentials, as code.
# ============================================================================
#
# NOT KEEP-IN-SYNC with stage-1 (deliberate). The tailnet is a single global
# entity — there is one ACL, one operator — so it's managed once, here in
# prod-1, the workspace that owns the adanalife-minipc cluster. stage-1 has no
# tailscale.tf.
#
# Credential flow mirrors the cloudflare provider (see secrets.tf +
# vault/decisions/secrets-manager-for-tf-providers.md): the provider's own
# bootstrap creds live in an SM container, populated out-of-band; everything
# else (the operator OAuth client, the node auth key) is TF-owned and written
# back into SM for ESO / the machine-config patch to consume.
#
# ── Two-phase first apply ───────────────────────────────────────────────────
#   1. Create just the bootstrap container (the provider can't auth yet):
#        task tf:prod:apply -- -target=aws_secretsmanager_secret.tailscale_oauth \
#                               -target=aws_secretsmanager_secret_version.tailscale_oauth
#   2. Populate it (one-time, your side). Create an OAuth client in the admin
#      console → Settings → OAuth clients with WRITE scopes
#      `policy_file`, `oauth_keys`, `auth_keys`, then:
#        aws-vault exec adanalife-prod -- aws secretsmanager put-secret-value \
#          --secret-id prod-1/tailscale-oauth \
#          --secret-string '{"client_id":"<id>","client_secret":"<secret>"}'
#   3. Full apply — the provider authenticates and the ACL + operator client +
#      node key all apply:
#        task tf:prod:apply
#   (If an OAuth-client credential turns out unable to *create* OAuth clients,
#    swap the bootstrap cred for a user API key — provider supports `api_key`.)

# --- Provider bootstrap credential (SM, out-of-band populated) ---------------

resource "aws_secretsmanager_secret" "tailscale_oauth" {
  name        = "prod-1/tailscale-oauth"
  description = "Bootstrap OAuth client for the tailscale Terraform provider."
}

resource "aws_secretsmanager_secret_version" "tailscale_oauth" {
  secret_id = aws_secretsmanager_secret.tailscale_oauth.id
  # Valid JSON so jsondecode() in the provider block doesn't choke before the
  # real value is populated; auth only actually fails when a tailscale_*
  # resource hits the API (which is why phase 1 above is -target'd to SM only).
  secret_string = jsonencode({ client_id = "placeholder", client_secret = "placeholder" })
  lifecycle {
    ignore_changes = [secret_string]
  }
}

data "aws_secretsmanager_secret_version" "tailscale_oauth" {
  secret_id = aws_secretsmanager_secret.tailscale_oauth.id
}

provider "tailscale" {
  oauth_client_id     = jsondecode(data.aws_secretsmanager_secret_version.tailscale_oauth.secret_string)["client_id"]
  oauth_client_secret = jsondecode(data.aws_secretsmanager_secret_version.tailscale_oauth.secret_string)["client_secret"]
  # Least-privilege: only what these resources touch (ACL + OAuth clients + keys).
  scopes = ["policy_file", "oauth_keys", "auth_keys"]
  # tailnet omitted → defaults to the tailnet owning the credential.
}

# --- Tailnet policy (ACL) ----------------------------------------------------

resource "tailscale_acl" "this" {
  # This resource was never `terraform import`ed, so the provider would
  # otherwise refuse to manage a non-empty policy. Setting this true declares
  # THIS file the single source of truth — edits made in the admin console are
  # reverted on the next apply. (Codifies the policy per the "codify the
  # Tailscale ACL as code" item in vault/infra/TODO.md.)
  overwrite_existing_content = true

  acl = <<-EOT
  {
      // ───────────────────────────────────────────────────────────────────
      // adanalife tailnet policy — MANAGED BY TERRAFORM
      // (infra/terraform/prod-1/tailscale.tf). Do NOT edit in the admin
      // console; changes there are overwritten on the next `terraform apply`.
      // ───────────────────────────────────────────────────────────────────

      // Tags which can be applied to devices, and who can assign them.
      "tagOwners": {
          // The cluster node (Talos subnet router) wears tag:k8s. Two owners:
          //   • autogroup:admin — so the node auth key (minted by TF below /
          //     the console) can be created carrying tag:k8s.
          //   • tag:k8s-operator — so the in-cluster operator can register the
          //     apiserver-proxy + per-Service proxy devices it creates with
          //     tag:k8s (the canonical operator pattern owns tag:k8s by
          //     tag:k8s-operator; we keep admin too so the node still works).
          "tag:k8s":          ["autogroup:admin", "tag:k8s-operator"],

          // Identity of the Tailscale Kubernetes operator and its OAuth client.
          // Admin-owned so TF (via the bootstrap credential) can mint the
          // operator OAuth client tagged tag:k8s-operator.
          "tag:k8s-operator": ["autogroup:admin"],
      },

      // Auto-approve the home LAN subnet (+ exit-node duty) advertised by the
      // cluster node, so it survives every wipe/re-register with no manual
      // clicks. Operator proxies wear tag:k8s too but advertise no routes, so
      // this only ever matches the subnet-router node itself.
      "autoApprovers": {
          "routes": {
              "192.168.1.0/24": ["tag:k8s"],
          },
          "exitNode": ["tag:k8s"],
      },

      // Grants govern access. Default allow-all — fine for a single-user
      // personal tailnet (every device is yours). Revisit if another person or
      // an untrusted identity ever joins the tailnet.
      "grants": [
          {"src": ["*"], "dst": ["*"], "ip": ["*"]},
      ],

      // Tailscale SSH. Won't touch the Talos node (it runs no SSH daemon — the
      // only way in is the Talos API over :50000), but it's handy/harmless for
      // your other devices: "check" forces a re-auth prompt before an SSH
      // session to one of your own machines.
      "ssh": [
          {
              "action": "check",
              "src":    ["autogroup:member"],
              "dst":    ["autogroup:self"],
              "users":  ["autogroup:nonroot", "root"],
          },
      ],
  }
  EOT
}

# --- Kubernetes operator OAuth client ----------------------------------------

# Minted by TF; the operator authenticates with these to register itself, the
# apiserver-proxy, and per-Service proxy devices on the tailnet.
resource "tailscale_oauth_client" "operator" {
  description = "Tailscale K8s operator (adanalife-minipc)"
  # devices:core (register proxy devices) + auth_keys (mint their join keys).
  # If a newer operator feature needs the `services` scope, add it here.
  scopes = ["devices:core", "auth_keys"]
  tags   = ["tag:k8s-operator"]
}

# Operator creds → SM (TF owns the value). ESO materializes these into the
# `operator-oauth` Secret in the `tailscale` namespace (keys client_id /
# client_secret) for the helm chart to consume.
resource "aws_secretsmanager_secret" "tailscale_operator_oauth" {
  name        = "k8s/tailscale/operator-oauth"
  description = "Tailscale K8s operator OAuth client credentials. Consumed by the operator via ESO."
}

resource "aws_secretsmanager_secret_version" "tailscale_operator_oauth" {
  secret_id = aws_secretsmanager_secret.tailscale_operator_oauth.id
  secret_string = jsonencode({
    client_id     = tailscale_oauth_client.operator.id
    client_secret = tailscale_oauth_client.operator.key
  })
}

# --- Node join key -----------------------------------------------------------

# Reusable, pre-authorized key the Talos node uses to join the tailnet on each
# (re)install.
#
# ⚠️ The node reads this from its SOPS-sealed machine config
#    (talos/adanalife-minipc/tailscale.patch.yaml → ExtensionServiceConfig
#    TS_AUTHKEY), NOT via ESO — k8s/ESO don't exist yet at node-join time. So
#    after TF mints or rotates this key you must re-seal the new value into
#    that patch (`task talos:minipc:secrets:encrypt`) and commit.
# ⚠️ Auth keys expire (90 days max). The key must be valid AT wipe time, so
#    before a post-expiry wipe run `terraform apply -replace=tailscale_tailnet_key.node`
#    to mint a fresh one, then re-seal. (This is the treadmill we accepted when
#    migrating the hand-made key into TF — see vault/infra/TODO.md.)
resource "tailscale_tailnet_key" "node" {
  reusable      = true
  ephemeral     = false
  preauthorized = true
  expiry        = 7776000 # 90 days (the max)
  tags          = ["tag:k8s"]
  description   = "adanalife-minipc Talos node join key"
}

resource "aws_secretsmanager_secret" "tailscale_node_authkey" {
  name        = "prod-1/tailscale-node-authkey"
  description = "Reusable tag:k8s auth key for the adanalife-minipc Talos node. Re-sealed into the SOPS machine-config patch (not consumed via ESO)."
}

resource "aws_secretsmanager_secret_version" "tailscale_node_authkey" {
  secret_id     = aws_secretsmanager_secret.tailscale_node_authkey.id
  secret_string = tailscale_tailnet_key.node.key
}

# --- CI lifecycle grants -----------------------------------------------------

# Kept here (not in secrets.tf) so the KEEP-IN-SYNC secrets.tf doesn't diverge
# from stage-1 — tailscale is prod-1-only. Same shape as the per-secret grants
# in secrets.tf: read on the bootstrap container (the provider data-sources it
# during plan), full lifecycle + PutSecretValue on the two TF-owned containers.
data "aws_iam_policy_document" "ci_terraform_tailscale_secrets" {
  statement {
    sid       = "ReadBootstrap"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret", "secretsmanager:ListSecretVersionIds"]
    resources = [aws_secretsmanager_secret.tailscale_oauth.arn]
  }
  statement {
    sid = "ManageTFOwned"
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
      "secretsmanager:UpdateSecret",
      "secretsmanager:PutSecretValue",
    ]
    resources = [
      "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:prod-1/tailscale-oauth-*",
      "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:k8s/tailscale/operator-oauth-*",
      "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:prod-1/tailscale-node-authkey-*",
    ]
  }
}

resource "aws_iam_policy" "ci_terraform_tailscale_secrets" {
  name        = "AllowCITerraformManageProd1TailscaleSecrets"
  description = "CI read (bootstrap creds) + lifecycle (operator creds, node key) for the tailscale SM containers in prod-1."
  policy      = data.aws_iam_policy_document.ci_terraform_tailscale_secrets.json
}

resource "aws_iam_role_policy_attachment" "ci_terraform_tailscale_secrets" {
  role       = aws_iam_role.ci_terraform.name
  policy_arn = aws_iam_policy.ci_terraform_tailscale_secrets.arn
}
