# Argo CD — prod-1-only (Argo runs on the adanalife-minipc; the in-cluster
# aws-secretsmanager-cluster ClusterSecretStore reads this prod account). Kept in
# its own file rather than secrets.tf so the KEEP-IN-SYNC sibling
# terraform/stage-1/secrets.tf doesn't diverge — same reasoning as tailscale.tf.

# Read-only SSH deploy key Argo CD uses to clone the infra repo. Container only —
# the keypair is hand-generated (no terraform-side source), value set out-of-band,
# same pattern as the other k8s/* secrets here. In-cluster ESO materializes it
# into the `argocd-repo-infra` Secret (labeled argocd.argoproj.io/secret-type:
# repository), which Argo auto-discovers as a repo credential. See
# gitops/README.md and cdk8s/adanalife_k8s/constructs/argocd.py.
#
# Bootstrap (after `task tf:prod:apply` creates the container):
#   ssh-keygen -t ed25519 -C "argocd-infra-deploy-key" -f argocd_infra -N ''
#   gh repo deploy-key add argocd_infra.pub -R adanalife/infra --title "Argo CD (read-only)"
#   aws-vault exec adanalife-prod -- aws secretsmanager put-secret-value \
#     --secret-id k8s/argocd/repo-ssh-key --secret-string file://argocd_infra
#   rm argocd_infra argocd_infra.pub
resource "aws_secretsmanager_secret" "argocd_repo_ssh_key" {
  name        = "k8s/argocd/repo-ssh-key"
  description = "Read-only SSH deploy key for Argo CD to clone the infra repo. Consumed via ESO into the argocd-repo-infra repository Secret. Value set out-of-band (see argocd.tf header)."
}

resource "aws_secretsmanager_secret_version" "argocd_repo_ssh_key" {
  secret_id     = aws_secretsmanager_secret.argocd_repo_ssh_key.id
  secret_string = "placeholder — set via aws secretsmanager put-secret-value"
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# CI read grant — `terraform plan` refreshes this container + its placeholder
# version, so CITerraformRole needs GetSecretValue/DescribeSecret on it (same as
# the secrets in secrets.tf's bulk ci_terraform_secrets_read). Kept here rather
# than in that bulk list so the KEEP-IN-SYNC sibling stage-1/secrets.tf doesn't
# gain a prod-only ARN — same reasoning as tailscale.tf. No lifecycle/manage or
# PutSecretValue grant: the value is set out-of-band and SM-touching applies run
# locally (not in CI), per the secrets-manager-for-tf-providers ADR.
#
# Runtime read access (the actual GetSecretValue at reconcile time) is ESO's, not
# CI's — covered by the eso_reader `k8s/*` wildcard in eso.tf.
data "aws_iam_policy_document" "ci_terraform_argocd_repo_ssh_key_read" {
  statement {
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecretVersionIds",
    ]
    resources = [
      "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:k8s/argocd/repo-ssh-key-*",
    ]
  }
}

resource "aws_iam_policy" "ci_terraform_argocd_repo_ssh_key_read" {
  name        = "AllowCITerraformReadProd1ArgocdRepoSshKey"
  description = "Read access for CITerraformRole to refresh the k8s/argocd/repo-ssh-key SM secret during plan in prod-1."
  policy      = data.aws_iam_policy_document.ci_terraform_argocd_repo_ssh_key_read.json
}

resource "aws_iam_role_policy_attachment" "ci_terraform_argocd_repo_ssh_key_read" {
  role       = aws_iam_role.ci_terraform.name
  policy_arn = aws_iam_policy.ci_terraform_argocd_repo_ssh_key_read.arn
}
