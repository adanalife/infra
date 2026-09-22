# GitOps delivery (Argo CD)

The cdk8s app manifests are committed under `cdk8s/dist/` (the golden-file output
of `task cdk8s:synth`). Argo CD reconciles them from git, so **deploying becomes
"merge a PR that changes `dist/`"** — no `kubectl apply`, no toolchain in the
cluster, and Argo's diff shows real Kubernetes YAML.

This is the pre-render model (see `cdk8s/README.md`): Argo doesn't run cdk8s;
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
infra synthed to `dist/<env>-nfs-pv.k8s.yaml` (which no ApplicationSet globs)
and applied once per cluster via `task k8s:<env>:nfs-pv`. Only the matching PVC
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
   task gitops:diff    # read-only preview of what the apply would change
   task gitops:apply
   ```

   The three ApplicationSets fan out into the per-component / supporting / data
   Applications for each cutover env, all reconciling from git. New ones come up
   **OutOfSync** until synced — safe under manual sync.

## Cutover status

Both minipc envs are **cut over** — `prod-1` and `stage-1` apps/supporting/data all
run on cdk8s + Argo (the legacy Kustomize app manifests were deleted in
[#660](https://github.com/adanalife/infra/pull/660)). Stage cut over first as the
rehearsal; prod followed at a stream-off wipe that also moved postgres into the
isolated `prod-1-data` namespace.

`ServerSideApply=true` is on every unit so syncs **adopt** live objects (e.g. the
postgres PVC) by name rather than replacing them.

To flip an env's **apps** to continuous reconciliation, add it to
`AUTOSYNC_ENVS` in `argocd.py`, re-synth + commit, re-apply. stage-1 is already
there; prod-1 is held out deliberately. The **data** units stay manual forever.

## Removing an AppProject or ApplicationSet

`task gitops:apply` is a plain `kubectl apply`, so it **never deletes**. Dropping
a top-level Argo object from `cdk8s/dist` leaves the live one running, and an
orphaned ApplicationSet keeps regenerating its Applications — deleting the child
looks like it silently fails, because the generator puts it straight back.
(Removing an *element* from a generator does prune; the appset controller owns
that. Only top-level object removal strands.)

`task gitops:prune` reports what's live in `argocd` but no longer declared:

```sh
task gitops:prune                 # read-only report
task gitops:prune CONFIRM=yes     # delete, --cascade=orphan
```

It reads every manifest listed in the task's `GITOPS_MANIFESTS` var — currently
`argocd.k8s.yaml` + `platform-argo.k8s.yaml`. **A new manifest declaring
AppProjects or ApplicationSets must be added there**, or its objects get reported
as orphans. Argo's built-in `default` AppProject is skipped via
`GITOPS_PRUNE_SKIP`; it belongs to no manifest and is the fallback project.

Deletion is `--cascade=orphan` on purpose: removing an ApplicationSet otherwise
takes its generated Applications and their workloads with it, which is how
[#847](https://github.com/adanalife/infra/pull/847/changes) dropped the prod
stream for ~1 minute. The generated Applications survive the prune and are swept
deliberately afterwards with `argocd app delete <name> --cascade=false`. This is
also why pruning is its own gesture rather than a `--prune` flag on
`gitops:apply` — a synth bug that dropped an appset would otherwise delete prod
workloads on the next apply.

## Emergency stop (pausing an autosynced app)

Autosynced Applications selfHeal: a `kubectl scale --replicas=0` is reverted
within seconds. Don't fight the controller — turn its autosync off first. The
ApplicationSets carry `ignoreApplicationDifferences` on `/spec/syncPolicy`, so a
manual policy change on a *generated* Application sticks instead of being
stomped back by the ApplicationSet controller:

```sh
# 1. disable autosync on the noisy app(s) — survives the appset controller
argocd app set stage-1-obs-youtube --sync-policy none   # or the UI toggle
# 2. now scale down freely
kubectl -n stage-1 scale deploy --all --replicas=0
```

(`argocd … --core` needs the kube-context namespace set to `argocd`; a
`kubectl -n argocd patch application <app> --type=json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'`
does the same without the CLI.)

Cluster-wide big red button — stops ALL reconciliation at once, when there's no
time to pick apps:

```sh
kubectl -n argocd scale statefulset argocd-application-controller --replicas=0
```

**Recovery** for either path: re-apply `cdk8s/dist/argocd.k8s.yaml` (re-stamps
the declared sync policies) and/or scale the application-controller back up.
Anything still autosynced reconciles back to git immediately — make sure the
merged `dist/` describes the state you want *before* turning Argo back on.

## Platform stack (Argo-native Helm)

The git-declarable platform charts (ESO, cert-manager, node-exporter,
victoria-metrics, k8s-monitoring, tailscale-operator, NATS, CNPG, ARC,
metrics-server) are authored as **Argo Applications with
a multi-source Helm source** — the upstream chart (version-pinned) + the in-repo
`k8s/<component>/values.yml` via a `$values` ref. Argo runs `helm template`
in-cluster, so **no rendered charts land in git** — only the small Application
objects in `cdk8s/dist/platform-argo.k8s.yaml` (offline, committed, golden-gated).
Source: `cdk8s/adanalife_k8s/constructs/argo_platform.py`; the chart table is
`helm_platform.py` (shared with the legacy `cdk8s.Helm` render path). A separate,
intentionally broad **`platform` AppProject** governs them (platform installs CRDs
/ ClusterRoles / webhooks), distinct from the restrictive `tripbot` app project.

An Application can carry in-repo raw manifests as an extra source when they are
custom resources of a CRD its chart ships: `tailscale-operator` also delivers
`k8s/tailscale-operator/proxygroup.yml` (the `ingress-proxies` ProxyGroup), so the
proxy fleet syncs with the operator that reconciles it.

**Not Argo-managed — they stay task-installed (`task k8s:<env>:platform:up`):**

- **cilium** (the CNI Argo itself rides on) and **argo-cd** (its own install) — the
  bootstrap floor.
- **traefik** + **external-dns** — *host-coupled via `development` only*. prod-1 and
  stage-1 commit their target — the node's location-independent alias, a CNAME onto
  whichever location is active — in `k8s/traefik/values.prod-1.yml`
  (`ingressEndpoint.hostname`) and `k8s/external-dns/<env>/config.yml`
  (`--default-targets` plus `--force-default-targets`). `development` is the env whose
  target is the host's own public IP, written per-machine to a gitignored
  `values.local.yml`, so the pair stays task-installed.
- The kustomize-only bits (local-path-provisioner, intel-gpu/xpu, ESO
  cluster-store, cert-manager ClusterIssuers).

**Argo is the delivery path for everything in the list above** — adoption of the
live helm releases completed 2026-07-16. Day-2 changes (values edits, chart
bumps, new platform charts) go: edit `helm_platform.py` / the values files →
merge → `task gitops:apply` (if the Application specs changed; preview with
`task gitops:diff`) → sync in Argo. Do **not** `helm upgrade --install`
an adopted release against the live cluster: Argo owns the objects via
server-side apply, and helm's apply fails with `argocd-controller`
field-manager conflicts. The remaining `helm upgrade --install` steps in
`task k8s:<env>:platform:up` exist for day-0 bring-up of an empty cluster only
(where Argo adopts them afterwards). Retiring them in favor of an
argo-sync-based bring-up is still open.

### Adoption (deliberate, NOT merge-and-forget)

How the live helm releases were adopted (kept as the playbook for adopting any
future not-yet-Argo-managed release). Argo *adopts* releases that
`helm upgrade --install` owns, so the risk is Helm/SSA field-manager conflicts.
Mirror the app cutover:

1. `task gitops:apply` — the project + Applications
   come up **OutOfSync, monitor-only**; nothing changes.
2. Review each Application's diff vs the live release in the Argo UI.
3. **Rehearse on stage** — sync `stage-1-nats` (the only stage-scoped Application now
   that external-dns is excluded); confirm NATS stays healthy.
4. Adopt the cluster-scoped charts one at a time in a maintenance window. Highest
   care: **tailscale-operator** (serves the Argo UI's own tailnet Ingress — keep a
   `kubectl port-forward` ready). `ServerSideApply=true` adopts live objects; sync
   with **prune off** and verify the diff first.
5. Once a release is cleanly Synced, retire its `helm upgrade --install` step.

> Namespace pod-security labels (e.g. the NATS PSS hardening) are applied by
> `bootstrap`, not these charts — `CreateNamespace=true` only creates a bare
> namespace on a fresh cluster.

## development on the k3d cluster (its own Argo)

`development` runs a **separate, independent Argo CD install** on its local k3d
cluster rather than being managed cross-cluster from the minipc. Each Argo targets
its **own** cluster in-cluster (`https://kubernetes.default.svc`), so there's no
inbound reachability to the residential dev box — it only needs outbound git, same
as the minipc Argo. The dev cluster can be off whenever; when it's up, its Argo
reconciles.

The config is authored by the **same** `ArgoCD` construct, parameterized to a
different env-set → `cdk8s/dist/argocd-k3d.k8s.yaml`: the `tripbot` project + the
three ApplicationSets scoped to `development` only, **no tailscale UI** (the dev
cluster has no tailscale-operator — reach the UI by port-forward), and
`development` apps on **automated sync** (the env is throwaway). The data unit
stays `Prune=false`.

Bring-up is folded into `task k8s:dev:platform:up`: it installs argo-cd on the dev
cluster (`-f k8s/argo-cd/values.yml -f k8s/argo-cd/values.k3d.yml`) and applies
`argocd-k3d.k8s.yaml`. The one out-of-band step is seeding the read-only repo
deploy key at `k8s/argocd/repo-ssh-key` in the **stage** SM (dev borrows the
adanalife-stage account); the same GitHub deploy key works.

**UI:** a traefik Ingress at `http://argocd.dev.whereisdana.today:9080` (the `:9080`
is the k3d port-map of traefik's `:80`; external-dns publishes the record to the
LAN endpoint, no TLS). Mirrors the minipc's `argocd.prod.whereisdana.today` — no
port-forward. (`kubectl -n argocd port-forward svc/argocd-server 8080:80` is the
fallback.)

**First sync:** `data` + `supporting` are manual (data is `Prune=false` forever);
the apps autosync. `task k8s:dev:argo:sync` syncs them in dependency order
(`development-data` → `development-supporting` → apps) via `argocd --core`.

## Not covered yet

- **traefik / external-dns / cilium / argo-cd** — stay task-installed (above).
- **One-shot Jobs** — stay task-driven (they'd re-run on every sync).
