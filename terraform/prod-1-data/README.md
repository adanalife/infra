# terraform/prod-1-data

The prod-1 account's **irreplaceable** resources, in their own state file
(`adanalife-core-tf-state` / `prod-1-data.tfstate`). Same account and same
credentials as `terraform/prod-1` — the split is a blast-radius boundary, not
an identity. The `-data` suffix matches the `prod-1-data` Kubernetes namespace
and Argo's `-data` ApplicationSets: the layer nothing may casually recreate.

## What belongs here

A resource goes here when **destroying and recreating it loses something that
cannot be regenerated from this repo.** The current tenants:

- `sops.tf` — the KMS key sealing the adanalife-minipc Talos PKI. Losing it
  makes every committed `talos/adanalife-minipc/*.sops.yaml` permanently
  undecryptable. Already carried `prevent_destroy` before the split.
- `postgres-backup.tf` — the bucket holding the postgres dumps, including the
  `archive/` prefix that has no lifecycle rule and is meant to live forever.

A DNS record, an IAM role, a Pages project or a Grafana dashboard does *not*
belong here — terraform can rebuild all of those from the tree. Stay strict:
the value of this workspace is entirely in what it excludes.

## Why a separate state and not just `prevent_destroy`

`prevent_destroy` stops `terraform destroy`; it does not stop a bad plan
applied by something holding admin credentials. Burrito's `overrideRunnerSpec`
is per-layer rather than per-action, so a workspace whose layer can apply runs
its hourly drift *plan* as an administrator too
(`cdk8s/adanalife_k8s/constructs/burrito.py`). Splitting the state is the only
way to give the irreplaceable resources a layer whose credential is read-only,
which is what this directory exists to make possible.

## Gestures

`task tf:prod-data:{plan,apply,init,destroy}` — the same `aws-vault exec
adanalife-prod` wrapper as `tf:prod:*`.
