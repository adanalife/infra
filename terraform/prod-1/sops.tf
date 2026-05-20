# SOPS encryption key for the adanalife-minipc Talos PKI.
#
# The generated Talos machine configs (controlplane.yaml / worker.yaml) and
# talosconfig hold the cluster CA private key, the bootstrap + trustd join
# tokens, and the etcd / secretbox encryption secrets. Losing them means
# losing the ability to authenticate to or rebuild the cluster, so they are
# SOPS-encrypted with this key and committed as
# talos/adanalife-minipc/*.sops.yaml (the plaintext stays gitignored).
#
# prod-1-only (not a KEEP-IN-SYNC sibling of stage-1): the PKI belongs to the
# single mini-PC Talos cluster, which stage-1 will later co-tenant rather than
# run its own control plane.
#
# Workflow + bootstrap order: vault/infra/adanalife-minipc-bootstrap.md Phase 4.
# Encrypt/decrypt via `task talos:minipc:secrets:{encrypt,decrypt}`.

resource "aws_kms_key" "sops_talos_pki" {
  description = "SOPS key for the adanalife-minipc Talos PKI bundle (controlplane/worker/talosconfig)."

  # Two layers of protection — losing this key makes every committed
  # *.sops.yaml permanently undecryptable:
  #   - deletion_window_in_days: AWS-side 30-day (max) recovery window before
  #     a *scheduled* deletion actually destroys the key material.
  #   - prevent_destroy: blocks terraform from scheduling deletion at all, so
  #     a `terraform destroy` / accidental removal of prod-1 errors out here.
  deletion_window_in_days = 30

  # Rotation intentionally off: this key only wraps SOPS data keys for a tiny,
  # rarely-read bundle (decrypt fires a handful of times a year), so annual
  # rotation just adds AWS cost for no meaningful benefit.
  enable_key_rotation = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "sops_talos_pki" {
  name          = "alias/sops-talos-pki"
  target_key_id = aws_kms_key.sops_talos_pki.key_id
}

# Read by `task talos:minipc:secrets:encrypt` (passed to `sops -e --kms`).
# Decryption doesn't need this — sops reads the key ARN from each encrypted
# file's own metadata.
output "sops_talos_kms_key_arn" {
  description = "ARN of the KMS key SOPS uses to seal the adanalife-minipc Talos PKI."
  value       = aws_kms_key.sops_talos_pki.arn
}
