# GitOps delivery (Argo CD)

The cdk8s app manifests are committed under `cdk8s/dist/` (the golden-file output
of `task cdk8s:synth`). Argo CD reconciles them from git, so **deploying becomes
"merge a PR that changes `dist/`"** — no `kubectl apply`, no toolchain in the
cluster, and Argo's diff shows real Kubernetes YAML.

This is the pre-render model (see the cdk8s ADR + README): Argo doesn't run cdk8s;
it tracks the plain manifests cdk8s already produced. Same story would work for
Flux pointed at `cdk8s/dist/` — Argo is chosen for the UI.

> **Sync policy is per-env.** The Applications default to **manual sync** (no
> automated prune/selfHeal): Argo shows Synced/OutOfSync + a diff and waits — no
> workload is touched until you click Sync. That was the cutover safety net.
> Post-cutover, **stage-1 apps run automated** (prune + selfHeal) so a merged
> `dist/` change deploys itself; **prod-1 apps stay manual** until we're confident,
> and **both `*-data` units stay manual + `Prune=false` forever** — that's the
> guarantee a deploy can never delete the database or volumes.

## What's here

All the Argo config is authored in cdk8s (no hand-written YAML) and synthesized to
**`cdk8s/dist/argocd.k8s.yaml`** — a committed, golden-gated deploy unit. Source:
`cdk8s/adanalife_k8s/constructs/argocd.py`. It contains:

- an **`AppProject`** (`tripbot`) — restrictive: only the infra repo, only the
  in-cluster app + data namespaces (`prod-1`, `stage-1`, `prod-1-data`,
  `stage-1-data`), and only the cluster-scoped kinds the apps use (PV,
  StorageClass). Caps blast radius vs the wide-open `default` project. (The
  `infra`/`platform` project names are reserved for shared cluster infrastructure;
  these are tripbot-project app workloads.)
- **three `ApplicationSet`s**, so every deploy unit is its own sync/health/URL:
  - `tripbot-apps` — **one Application per `<env>-<component>-<platform>`** (each of
    tripbot/vlc/onscreens/obs × env × platform reconciles its own
    `cdk8s/dist/<env>-<component>-<platform>.k8s.yaml`).
  - `tripbot-supporting` — one Application per env (shared observability Secrets +
    cert-manager Issuers + tripbot identity Secrets).
  - `tripbot-data` — one Application per env, targeting `env.data_ns` (the isolated
    `<env>-data` namespace where it exists). **`Prune=false`** — never deletes the
    postgres StatefulSet / PVCs.
  - `ignoreDifferences` keeps two sets of apiserver-defaulted fields out of every
    diff: ESO's `ExternalSecret` CRD schema defaults, and the
    `apiVersion`/`kind` the apiserver stamps onto StatefulSet `volumeClaimTemplates`.
- a **tailscale `Ingress`** — UI at `argocd-prod.<tailnet>.ts.net`.
- a repo-registration **`ExternalSecret`** (IaC — see step 2).

The dashcam **PV** is deliberately **not** in Argo — it's host-specific bootstrap
infra synthed to `dist/<env>-dashcam-pv.k8s.yaml` (which no ApplicationSet globs)
and applied once per cluster via `task k8s:<env>:dashcam-pv`. Only the matching PVC
is Argo-managed (in the data unit); it binds to the named PV.

Argo CD itself is installed by the **cdk8s platform layer** (`PlatformChart`,
minipc) — chart pinned in `helm_platform.py`, Helm values in `k8s/argo-cd/values.yml`.

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

3. **Apply the Argo config** (project + appsets + ingress + repo secret):

   ```sh
   kubectl apply -f cdk8s/dist/argocd.k8s.yaml
   ```

   The three ApplicationSets fan out into the per-component / supporting / data
   Applications for each cutover env, all reconciling from git. New ones come up
   **OutOfSync** until synced — safe under manual sync.

## Cutover status

Both minipc envs are **cut over** — `prod-1` and `stage-1` apps/supporting/data all
run on cdk8s + Argo (the legacy Kustomize app manifests were deleted in
[#660](https://github.com/adanalife/infra/pull/660)). Stage cut over first as the
rehearsal; prod followed at a stream-off wipe that also moved postgres into the
isolated `prod-1-data` namespace (see `vault/sessions/2026-06-09-prod-data-namespace-cutover`).

`ServerSideApply=true` is on every unit so syncs **adopt** live objects (e.g. the
postgres PVC) by name rather than replacing them.

To flip an env's **apps** to continuous reconciliation, add it to
`AUTOSYNC_ENVS` in `argocd.py`, re-synth + commit, re-apply. stage-1 is already
there; prod-1 is held out deliberately. The **data** units stay manual forever.

## Not covered yet

- **development** (bees cluster) — needs that cluster registered with Argo
  (`argocd cluster add`) and a third env added to the ApplicationSet generators
  pointing at its destination server.
- **Platform Helm** — being migrated to Argo-native Helm Applications (see the
  cdk8s README); until then it stays task-driven (`task k8s:<env>:platform:up`).
- **One-shot Jobs** — stay task-driven (they'd re-run on every sync).
