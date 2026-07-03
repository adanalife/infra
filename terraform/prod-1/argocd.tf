# Argo CD — prod-1-only (Argo runs on the adanalife-minipc; the in-cluster
# aws-parameterstore-cluster ClusterSecretStore reads this prod account). Kept
# in its own file rather than secrets.tf so the KEEP-IN-SYNC sibling
# terraform/stage-1/secrets.tf doesn't diverge — same reasoning as tailscale.tf.
#
# Read-only SSH deploy keys Argo CD uses to clone its source repos. The
# keypairs are hand-generated (no terraform-side source), values set
# out-of-band. In-cluster ESO materializes each into the corresponding
# `argocd-repo-*` Secret (labeled argocd.argoproj.io/secret-type: repository),
# which Argo auto-discovers as a repo credential. See gitops/README.md and
# cdk8s/adanalife_k8s/constructs/argocd.py.
#
# Bootstrap dance, once per repo (infra shown; console / video-pipeline /
# platform-gateway are identical with their own key names):
#   ssh-keygen -t ed25519 -C "argocd-infra-deploy-key" -f argocd_infra -N ''
#   gh repo deploy-key add argocd_infra.pub -R adanalife/infra --title "Argo CD (read-only)"
#   aws-vault exec adanalife-prod -- aws ssm put-parameter \
#     --name /k8s/argocd/repo-ssh-key --type SecureString \
#     --overwrite --value "$(cat argocd_infra)"
#   rm argocd_infra argocd_infra.pub
#
# CI read/lifecycle rides the account-wide SSM statements in secrets.tf's
# ci_terraform_secrets_read. Runtime read access (at reconcile time) is ESO's —
# the eso_reader parameter/k8s/* grant in eso.tf.

locals {
  argocd_ssm_parameters = {
    "k8s/argocd/repo-ssh-key"                  = "Read-only SSH deploy key for Argo CD to clone the infra repo. Consumed via ESO into the argocd-repo-infra repository Secret."
    "k8s/argocd/repo-ssh-key-console"          = "Read-only SSH deploy key for Argo CD to clone the private tripbot-console repo. Consumed via ESO into the argocd-repo-tripbot-console repository Secret."
    "k8s/argocd/repo-ssh-key-video-pipeline"   = "Read-only SSH deploy key for Argo CD to clone the private video-pipeline repo. Consumed via ESO into the argocd-repo-video-pipeline repository Secret."
    "k8s/argocd/repo-ssh-key-platform-gateway" = "Read-only SSH deploy key for Argo CD to clone the private platform-gateway repo. Consumed via ESO into the argocd-repo-platform-gateway repository Secret."
  }
}

# Resource label kept as "argocd_mirror" from the SM → SSM migration to avoid
# state moves; these are now the canonical (only) home of each key.
resource "aws_ssm_parameter" "argocd_mirror" {
  for_each = local.argocd_ssm_parameters

  name        = "/${each.key}"
  description = each.value
  type        = "SecureString"
  value       = jsonencode({ placeholder = "set via aws ssm put-parameter" })

  lifecycle {
    ignore_changes = [value]
  }
}
