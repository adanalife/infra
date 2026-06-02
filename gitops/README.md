# GitOps delivery (Argo CD)

The cdk8s app manifests are committed under `cdk8s/dist/` (the golden-file output
of `task cdk8s:synth`). Argo CD reconciles them from git, so **deploying becomes
"merge a PR that changes `dist/`"** — no `kubectl apply`, no toolchain in the
cluster, and Argo's diff shows real Kubernetes YAML.

This is the pre-render model (see the cdk8s ADR + README): Argo doesn't run cdk8s;
it tracks the plain manifests cdk8s already produced. Same story would work for
Flux pointed at `cdk8s/dist/` — Argo is chosen for the UI.

> **Monitor-only right now.** This whole setup is wired so Argo **watches and
> reports drift but changes nothing.** The Applications are **manual-sync** (no
> automated prune/selfHeal), so Argo shows Synced/OutOfSync + a diff and waits —
> no workload is touched until you click Sync. That's the cutover safety: stand it
> up, watch the diffs, then sync deliberately, per env.

## What's here

All the Argo config is authored in cdk8s now (no hand-written YAML) and synthesized
to **`cdk8s/dist/argocd.k8s.yaml`** — a committed, golden-gated deploy unit. Source:
`cdk8s/adanalife_k8s/constructs/argocd.py`. It contains:

- an **`AppProject`** (`adanalife-apps`) — restrictive: only the infra repo, only the
  in-cluster `prod-1`/`stage-1` namespaces, only the cluster-scoped kinds the apps
  use (PV, StorageClass). Caps blast radius vs the wide-open `default` project.
- an **`ApplicationSet`** — one Application per minipc env reconciling
  `cdk8s/dist/<env>-apps.k8s.yaml`. **Manual sync** (monitor-only); `ignoreDifferences`
  keeps the dashcam PV's NFS placeholders out of the diff. One-shot Jobs + platform
  Helm are out of scope.
- a **tailscale `Ingress`** — UI at `argocd-prod.<tailnet>.ts.net`.
- a repo-registration **`ExternalSecret`** (IaC — see step 2).

Argo CD itself is installed by the **cdk8s platform layer** (`PlatformChart`, minipc)
— chart pinned in `helm_platform.py`, Helm values in `k8s/argo-cd/values.yml`.

Nearly all of this is declarative. The only out-of-band step is seeding the repo
deploy key into SM + adding its public half to GitHub (a one-time bootstrap, like
every other ESO-backed secret).

## Bootstrap (one-time, on the mini-PC)

1. **Install Argo CD** — `task k8s:prod:platform:up` installs it as part of the
   platform bring-up (pinned argo-cd `9.5.17`, values `k8s/argo-cd/values.yml`); no
   manual `helm repo add` / `helm install`. (It's also a component of the cdk8s
   `PlatformChart` for when the platform itself cuts over to cdk8s.) It installs
   idle: a controller watching nothing until the Applications below exist. The UI
   comes up at `https://argocd-prod.<tailnet>.ts.net` via the tailscale Ingress
   (applied in step 2) — or `kubectl -n argocd port-forward svc/argocd-server 8080:443`.

2. **Register the infra repo — declaratively (IaC).** Argo auto-discovers repos
   from Secrets labeled `argocd.argoproj.io/secret-type: repository`, and the repo
   `ExternalSecret` (in `argocd.py`) makes ESO materialize exactly that from a
   read-only SSH deploy key in AWS Secrets Manager. So you don't run
   `argocd repo add` — just the one-time bootstrap (generate the deploy key, add the
   public half to GitHub as read-only, store the private half at
   `k8s/argocd/repo-ssh-key` in prod's SM). It's applied with the config below.

3. **Apply the Argo config** (project + appset + ingress + repo secret):

   ```sh
   kubectl apply -f cdk8s/dist/argocd.k8s.yaml
   ```

   Argo creates `prod-1-apps` + `stage-1-apps`, both **OutOfSync** (nothing synced
   yet). This is safe — manual sync is on.

## Cutover with Argo (replaces the `kubectl apply` cutover)

For each env, lowest-risk first:

1. Open the Application in the Argo UI and review the diff vs the live (Kustomize)
   state — this is the same signal as `task cdk8s:<env>:diff`.
2. For **stage-1**: sync. Watch the rollout; run the integration suite
   (`cd cdk8s && uv run pytest tests/integration --env stage-1`).
3. For **prod-1**: sync in a stream-off window (the OBS `obs`→`obs-twitch` rename
   is delete/create). `ServerSideApply=true` adopts the live postgres PVC by name
   rather than replacing the StatefulSet — verify in the diff first.
4. Once both envs are clean on cdk8s, enable continuous reconciliation: uncomment
   the `automated: {prune, selfHeal}` block in `argocd.py`, re-synth + commit, and
   re-apply. From then on a merged `dist/` change deploys itself.

## The dashcam PV caveat

`cdk8s/dist/<env>-apps.k8s.yaml` ships the dashcam `PersistentVolume` with NFS
**placeholders** (the one host-specific object). Before prod/stage sync cleanly,
either apply the real PV out-of-band (as the gitignored kustomize
`dashcam-nfs.local.yaml` did) or have Argo ignore that object. The PVC binds to
the named PV regardless.

## Not covered yet

- **development** (bees cluster) — needs that cluster registered with Argo
  (`argocd cluster add`) and a third ApplicationSet element pointing at its
  destination server.
- **Platform Helm + one-shot Jobs** — stay task-driven (Jobs would re-run on
  every sync; the platform stack isn't committed to `dist/`).
