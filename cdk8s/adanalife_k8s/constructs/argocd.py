"""Argo CD GitOps config, authored in cdk8s (was plain YAML under gitops/ +
k8s/argo-cd/). Synthesizes to dist/argocd.k8s.yaml — a committed, golden-gated
deploy unit applied after the Argo install (which is the Helm chart in
PlatformChart). Argo CD itself is the controller; these are the objects that tell
it what to watch:

  * AppProjects — one per source repo, each a restrictive tenancy boundary: its
    single repo in sourceRepos, only the namespaces its apps target, only the
    cluster-scoped kinds those apps actually create. Caps the blast radius vs the
    wide-open `default` project AND vs a shared project (a misconfigured
    Application can't pull from another repo or sync into another tenant's
    namespace). The four: `tripbot` (apps + identity, tripbot repo), `infra`
    (postgres data + supporting, infra repo), `tripbot-console` and
    `video-pipeline` (the two private cross-repo sources).
  * ApplicationSets — `tripbot-apps` (one Application per
    <env>-<component>-<platform>) + `tripbot-identity` (per-env identity Secrets +
    stream protection) source the TRIPBOT repo (the app manifests live there now);
    `tripbot-supporting` and `tripbot-data` (one per env) source infra. Each
    reconciles its own cdk8s/dist file. The apps set runs automated (prune +
    selfHeal) for AUTOSYNC_ENVS minus AUTOSYNC_HOLDOUTS (prod OBS stays manual — a
    sync restarts the live stream); identity + supporting + data are manual
    everywhere (identity + data also Prune=false — never GC creds/volumes), so
    Argo reports their drift but changes nothing until you sync. ignoreDifferences
    keeps ESO's CRD schema-default fields out of the diff so ExternalSecrets read
    Synced.
  * tailscale Ingress — the UI at argocd-prod.<tailnet>.ts.net.
  * traefik Ingress — the same UI at argocd.prod.whereisdana.today, published by
    external-dns to the cluster's LAN endpoint (reachable on-LAN directly, off-LAN
    via the tailscale subnet route). cert-manager issues the cert via the route53
    ClusterIssuer. Mirrors the apps' traefik+tailscale dual exposure.
  * repo ExternalSecret — IaC repo registration: ESO materializes the
    Argo-recognized `repository` Secret from a read-only deploy key in SM.
  * notifications ExternalSecret — the Discord webhook for the notifications
    controller (sync-failed / health-degraded pings; config in
    k8s/argo-cd/values.yml), from the same SM container the Grafana alerts use.

Argo CRDs (AppProject/ApplicationSet) are emitted via ApiObject — they're one-off
objects, so (like SecretStore) the typed-import cost isn't worth it.
"""

from __future__ import annotations

import cdk8s
import imports.io.external_secrets as esx
import imports.k8s as k8s
from constructs import Construct

REPO_URL = "git@github.com:adanalife/infra.git"
TARGET_REVISION = "master"
ARGO_NS = "argocd"
# One AppProject per source repo — a per-repo tenancy boundary so an Application
# can only ever pull from its one repo and sync into its own namespaces (see the
# module docstring). `tripbot` governs the app workloads + identity (tripbot
# repo); `infra` the postgres data + supporting (infra repo); the two private
# cross-repo sources get their own.
TRIPBOT_PROJECT = "tripbot"
INFRA_PROJECT = "infra"
CONSOLE_PROJECT = "tripbot-console"
VIDEO_PIPELINE_PROJECT = "video-pipeline"
# The cluster-scoped kinds each project's apps create. Scoped per project from
# the dist each repo emits: tripbot's identity unit + video-pipeline each declare
# the prod-stream PriorityClass; infra's data/supporting use a StorageClass and
# (dashcam) PersistentVolumes; the console creates nothing cluster-scoped.
PV = {"group": "", "kind": "PersistentVolume"}
STORAGE_CLASS = {"group": "storage.k8s.io", "kind": "StorageClass"}
PRIORITY_CLASS = {"group": "scheduling.k8s.io", "kind": "PriorityClass"}
IN_CLUSTER = "https://kubernetes.default.svc"
# The minipc Argo manages these envs in-cluster. development runs its OWN Argo on
# the k3d dev cluster (a separate install reconciling development against that
# cluster's own in-cluster API — no cross-cluster networking). The ArgoCD construct
# is parameterized by env-set so both instances share one authoring path; see
# main.py (argocd = minipc, argocd-k3d = the dev cluster).
ENVS = ("prod-1", "stage-1")
# Envs migrated to the per-component topology. Stage cut over first; prod now
# joins at its own wipe — the per-component topology AND the postgres data-
# namespace move land together in one prod wipe (config.prod-1.data_namespace).
# The live legacy adanalife-* ApplicationSets + AppProject are deleted by hand
# during that wipe (they collide with the new sets on the shared `{env}-data`
# Application name, so they can't coexist).
CUTOVER_ENVS = ENVS
# Envs whose *apps* run automated (prune + selfHeal) — a merged dist/ change
# deploys itself. Applied per-env via a templatePatch on the apps ApplicationSet,
# so the rest stay manual. stage-1 led; prod-1 joined once the version pins made
# merge-to-master a deliberate deploy gesture (versions.yaml bump PRs). The DATA
# units NEVER autosync (Prune=false is their guarantee); supporting stays manual
# too — only the apps set reads this.
AUTOSYNC_ENVS = ("stage-1", "prod-1")
# (env, app) pairs held out of autosync even when their env is automated. OBS is
# the live encoder: any pod-template change restarts the prod stream, so deploys
# to it stay a deliberate manual sync (pick the quiet moment), while the rest of
# prod autosyncs.
AUTOSYNC_HOLDOUTS = (("prod-1", "obs-twitch"),)
TAILNET_HOST = "argocd-prod"  # -> argocd-prod.<tailnet>.ts.net
# LAN-reachable UI host published by external-dns to the cluster's LAN endpoint.
# Argo is a prod-only install (it governs both prod-1 + stage-1), so the host
# lives under the prod subdomain alongside the apps (vlc-twitch.prod...) and the
# traefik dashboard.
LAN_HOST = "argocd.prod.whereisdana.today"
REPO_SM_KEY = "k8s/argocd/repo-ssh-key"
# Discord webhook for the notifications controller — deliberately the SAME SM
# container tripbot's reportCmd and the Grafana alerts read (one channel, one
# webhook, already seeded in both accounts), not a new argocd-scoped secret.
NOTIFICATIONS_SM_KEY = "k8s/tripbot/discord-alerts-webhook"
# The private tripbot-console repo — Argo's second source. Its cdk8s/dist
# deploy units (one <env>.k8s.yaml per env) live in that repo, per the split
# design: the console repo owns its own deployment; infra owns everything else.
CONSOLE_REPO_URL = "git@github.com:adanalife/tripbot-console.git"
CONSOLE_REPO_SM_KEY = "k8s/argocd/repo-ssh-key-console"
# Per-env git revision for the console units: stage tracks develop (manifests
# float alongside the :develop image), prod tracks master (release-gated) —
# the same philosophy as the image-tag pinning model.
CONSOLE_REVISIONS = {"prod-1": "master", "stage-1": "develop"}
# The private video-pipeline repo — another cross-repo source (same split as the
# console: the repo owns its own cdk8s/dist deploy units). The dashcam-cv embed
# workload it delivers is stage-only today, so only stage-1 has a revision.
VIDEO_PIPELINE_REPO_URL = "git@github.com:adanalife/video-pipeline.git"
VIDEO_PIPELINE_REPO_SM_KEY = "k8s/argocd/repo-ssh-key-video-pipeline"
VIDEO_PIPELINE_REVISIONS = {"stage-1": "develop"}
# The tripbot repo — Argo's source for the APP workloads (the four images built
# from it: tripbot/vlc/onscreens/obs) once they migrate out of infra/cdk8s. It's
# PUBLIC, so Argo fetches it over anonymous https — no deploy key / repo Secret
# (unlike the infra + console SSH sources). tripbot's dist filenames + path
# ("cdk8s/dist/<env>-<app>.k8s.yaml") are identical to infra's, so only the
# source repo + revision change per env.
TRIPBOT_REPO_URL = "https://github.com/adanalife/tripbot.git"
# Per-env revision: prod rides master (release-gated), stage + dev ride develop
# (manifests float with the :develop image) — same philosophy as the console +
# the image-tag pins. (local isn't Argo-managed — it kubectl-applies tripbot's
# dist directly.)
TRIPBOT_REVISIONS = {"prod-1": "master", "stage-1": "develop", "development": "develop"}
# Envs whose APP workloads + identity Secrets Argo reads from the tripbot repo
# instead of infra. Every Argo-managed env is now cut over: prod-1/stage-1 on the
# minipc and development on the k3d cluster. infra no longer authors any tripbot
# app manifests — it delivers them cross-repo (see the apps + identity
# ApplicationSets below) and keeps only postgres/supporting/dashcam.
TRIPBOT_APPS_ENVS = ("stage-1", "prod-1", "development")
# The tripbot APP components — one Application per (env, component, platform). The
# matching dist files (`<env>-<component>-<platform>.k8s.yaml`) are authored in
# the tripbot repo now, so this list is a cross-repo contract: it must track the
# components tripbot's cdk8s emits, or the apps set would generate Applications
# pointing at files that don't exist (or miss new ones). Lived in charts.py while
# infra emitted the apps; it's now purely an Argo-config concern.
TRIPBOT_COMPONENTS = ("tripbot", "vlc", "onscreens", "obs")


def _data_ns(env_name: str) -> str:
    """The namespace the data unit deploys into for an env — env.data_ns (its own
    isolated namespace when set, else the app namespace). Lazy import avoids the
    charts.py <-> argocd.py cycle."""
    from adanalife_k8s.config import load_env

    return load_env(env_name).data_ns


def _project_namespaces(envs: tuple[str, ...]) -> list[str]:
    """Every namespace an Application in this project may target: the app
    namespaces plus any isolated data namespace (e.g. stage-1-data). Drives the
    AppProject `destinations` allowlist — an Application can't sync into a
    namespace the project doesn't permit."""
    seen: list[str] = list(envs)
    for e in envs:
        ns = _data_ns(e)
        if ns not in seen:
            seen.append(ns)
    return seen


def _app_elements(envs: tuple[str, ...]) -> list[dict]:
    """The per-component ApplicationSet elements: one {env, app} per
    (env, platform, component), where app = "<component>-<platform>". Every env's
    app workloads are authored in the tripbot repo now, so each element sources it
    at the env's revision (prod→master, stage/dev→develop). The component list +
    each env's platforms drive the (env, platform, component) fan-out; it must
    stay in sync with the dist files tripbot's cdk8s emits. Lazy config import
    avoids an import cycle (config has no cycle, but kept local for symmetry)."""
    from adanalife_k8s.config import load_env

    elements: list[dict] = []
    for env_name in envs:
        revision = TRIPBOT_REVISIONS[env_name]
        for platform in load_env(env_name).platforms:
            for comp in TRIPBOT_COMPONENTS:
                elements.append(
                    {
                        "env": env_name,
                        "app": f"{comp}-{platform}",
                        "repo": TRIPBOT_REPO_URL,
                        "revision": revision,
                    }
                )
    return elements


class ArgoCD(Construct):
    """The Argo CD config one cluster's Argo install reconciles. Parameterized by
    env-set so the same authoring path emits both the minipc instance (prod-1 +
    stage-1) and the k3d dev instance (development only). Each Argo targets its OWN
    cluster in-cluster, so there's no cross-cluster networking; the instances differ
    by which envs + how the UI is exposed:

      * `tailscale_ui` — emit the tailnet UI Ingress (minipc only; the dev cluster
        has no tailscale-operator).
      * `lan_host` — the traefik UI Ingress host (external-dns-published), or None
        for no traefik UI. minipc: argocd.prod.whereisdana.today; the k3d dev
        cluster: argocd.dev.whereisdana.today, reached at :9080 via the k3d
        port-map. `lan_tls` adds the cert-manager TLS block (minipc; off on dev)."""

    def __init__(
        self,
        scope: Construct,
        id: str = "argocd",
        *,
        envs: tuple[str, ...] = CUTOVER_ENVS,
        autosync_envs: tuple[str, ...] = AUTOSYNC_ENVS,
        autosync_holdouts: tuple[tuple[str, str], ...] = AUTOSYNC_HOLDOUTS,
        selfheal: bool = True,
        tailscale_ui: bool = True,
        lan_host: str | None = LAN_HOST,
        lan_tls: bool = True,
        notifications_secret: bool = True,
    ):
        super().__init__(scope, id)
        self.envs = envs
        # Whether the autosync block reconciles live drift (selfHeal). True on the
        # minipc (prod/stage must match git). False on the throwaway k3d dev
        # instance: autosync still deploys git changes, but a hand `kubectl edit`
        # sticks (Argo shows OutOfSync rather than stomping it) — dev is a scratch
        # env, so manual experimentation shouldn't be fought. The /spec/syncPolicy
        # emergency brake (ignoreApplicationDifferences) still applies on top.
        self._selfheal = selfheal
        # Envs whose console (the cross-repo tripbot-console unit) this Argo
        # delivers — the envs with a defined console revision. Resolves empty on
        # the k3d dev instance (development deploys via `task deploy:dev` in the
        # console repo; the dev cluster carries no private-repo deploy key).
        self.console_envs = tuple(e for e in envs if e in CONSOLE_REVISIONS)
        # Envs whose video-pipeline (cross-repo) unit this Argo delivers — empty
        # off any cluster not running stage-1 (development deploys via task).
        self.video_pipeline_envs = tuple(
            e for e in envs if e in VIDEO_PIPELINE_REVISIONS
        )
        # Envs whose apps this Argo reads from the tripbot repo (so the AppProject
        # allows that source). Resolves to () on any cluster not running a
        # cut-over env.
        self.tripbot_apps_envs = tuple(e for e in envs if e in TRIPBOT_APPS_ENVS)

        # One AppProject per source repo. console/video-pipeline only on the
        # cluster(s) that actually run those envs (empty -> skip the project).
        self._app_project(
            id="project-tripbot",
            name=TRIPBOT_PROJECT,
            description="tripbot app workloads (tripbot/vlc/onscreens/obs + identity), from the tripbot repo",
            source_repos=[TRIPBOT_REPO_URL],
            namespaces=list(self.envs),
            cluster_resources=[PRIORITY_CLASS],
        )
        self._app_project(
            id="project-infra",
            name=INFRA_PROJECT,
            description="shared cluster infrastructure (postgres data + supporting), from the infra repo",
            source_repos=[REPO_URL],
            namespaces=_project_namespaces(self.envs),
            cluster_resources=[PV, STORAGE_CLASS, PRIORITY_CLASS],
        )
        if self.console_envs:
            self._app_project(
                id="project-console",
                name=CONSOLE_PROJECT,
                description="tripbot-console admin dashboard, from the private tripbot-console repo",
                source_repos=[CONSOLE_REPO_URL],
                # The console deploys into its app namespace AND the isolated
                # data namespace (read-only RBAC for the live status views), so
                # it needs both destinations like the infra project does.
                namespaces=_project_namespaces(self.console_envs),
                cluster_resources=[],
            )
        if self.video_pipeline_envs:
            self._app_project(
                id="project-video-pipeline",
                name=VIDEO_PIPELINE_PROJECT,
                description="dashcam video-pipeline workloads, from the private video-pipeline repo",
                source_repos=[VIDEO_PIPELINE_REPO_URL],
                namespaces=list(self.video_pipeline_envs),
                cluster_resources=[PRIORITY_CLASS],
            )
        # ApplicationSets, one Application each per unit. The apps set is
        # per-COMPONENT (one Application per <env>-<component>-<platform> →
        # cdk8s/dist/<env>-<component>-<platform>.k8s.yaml in the TRIPBOT repo), so
        # each component is its own sync/health/URL. supporting + data + identity
        # are per-env. Data never prunes, so an app deploy can't delete the
        # database or volumes.
        self._application_set(
            id="appset-apps",
            name="tripbot-apps",
            project=TRIPBOT_PROJECT,
            elements=_app_elements(envs),
            app_name_tmpl="{{.env}}-{{.app}}",
            include_tmpl="{{.env}}-{{.app}}.k8s.yaml",
            prune_disabled=False,
            automated_envs=autosync_envs,
            automated_holdouts=autosync_holdouts,
            selfheal=self._selfheal,
            # Source repo + revision are per-element (see _app_elements): every env
            # reads the tripbot repo at its own revision (prod→master, else develop).
            repo_url="{{.repo}}",
            target_revision_tmpl="{{.revision}}",
        )
        # The cross-repo identity unit: tripbot's per-env identity Secrets (DB creds
        # + twitch/maps/discord ExternalSecrets) and the prod-stream PriorityClass/
        # ResourceQuota, sourced from the tripbot repo (`<env>-tripbot-identity`).
        # MANUAL sync + Prune=false, like the data unit: these are precious
        # credentials whose ExternalSecrets own (creationPolicy: Owner) the
        # materialized Secrets, so an accidental prune would GC live creds. Removing
        # one is a deliberate manual gesture. (Handoff from the old infra-emitted
        # identity-in-supporting: sync this set FIRST so it adopts the existing
        # ExternalSecrets by name, THEN sync supporting — see the PR runbook.)
        if self.tripbot_apps_envs:
            self._application_set(
                id="appset-identity",
                name="tripbot-identity",
                project=TRIPBOT_PROJECT,
                elements=[
                    {"env": e, "revision": TRIPBOT_REVISIONS[e]}
                    for e in self.tripbot_apps_envs
                ],
                app_name_tmpl="{{.env}}-tripbot-identity",
                include_tmpl="{{.env}}-tripbot-identity.k8s.yaml",
                prune_disabled=True,  # never GC a credential Secret
                repo_url=TRIPBOT_REPO_URL,
                target_revision_tmpl="{{.revision}}",
            )
        self._application_set(
            id="appset-supporting",
            name="tripbot-supporting",
            project=INFRA_PROJECT,
            elements=[{"env": e} for e in envs],
            app_name_tmpl="{{.env}}-supporting",
            include_tmpl="{{.env}}-supporting.k8s.yaml",
            prune_disabled=False,
        )
        self._application_set(
            id="appset-data",
            name="tripbot-data",
            project=INFRA_PROJECT,
            # The data unit deploys into env.data_ns (its own namespace when the DB
            # is isolated, e.g. stage-1-data), not the app namespace — so carry the
            # target namespace in each element rather than deriving it from env.
            elements=[{"env": e, "ns": _data_ns(e)} for e in envs],
            app_name_tmpl="{{.env}}-data",
            include_tmpl="{{.env}}-data.k8s.yaml",
            dest_ns_tmpl="{{.ns}}",
            # NEVER prune the stateful unit.
            prune_disabled=True,
        )
        # The cross-repo console unit: one Application per env, sourcing the
        # PRIVATE tripbot-console repo's committed dist (per-env revision —
        # stage follows develop, prod follows master). Same autosync posture
        # as the apps set.
        if self.console_envs:
            self._application_set(
                id="appset-console",
                name="tripbot-console",
                project=CONSOLE_PROJECT,
                elements=[
                    {"env": e, "revision": CONSOLE_REVISIONS[e]}
                    for e in self.console_envs
                ],
                app_name_tmpl="{{.env}}-console",
                include_tmpl="{{.env}}.k8s.yaml",
                prune_disabled=False,
                automated_envs=autosync_envs,
                selfheal=self._selfheal,
                repo_url=CONSOLE_REPO_URL,
                target_revision_tmpl="{{.revision}}",
            )
        # The cross-repo video-pipeline unit: one Application per env, sourcing the
        # PRIVATE video-pipeline repo's committed dist. The include is the exact
        # <env>.k8s.yaml (the persistent dashcam-cv workload) — the sibling
        # <env>-jobs.k8s.yaml one-shots are deliberately NOT globbed, so reconciles
        # never re-run them. Same autosync posture as the apps/console sets.
        if self.video_pipeline_envs:
            self._application_set(
                id="appset-video-pipeline",
                name="video-pipeline",
                project=VIDEO_PIPELINE_PROJECT,
                elements=[
                    {"env": e, "revision": VIDEO_PIPELINE_REVISIONS[e]}
                    for e in self.video_pipeline_envs
                ],
                app_name_tmpl="{{.env}}-video-pipeline",
                include_tmpl="{{.env}}.k8s.yaml",
                prune_disabled=False,
                automated_envs=autosync_envs,
                selfheal=self._selfheal,
                repo_url=VIDEO_PIPELINE_REPO_URL,
                target_revision_tmpl="{{.revision}}",
            )
        # UI exposure. The tailnet Ingress is minipc-only (tailscale-operator). The
        # traefik/LAN Ingress is published on every cluster with a DNS host —
        # external-dns publishes the record either way; the dev cluster reaches it
        # at http://<lan_host>:9080 via the k3d port-map (no TLS).
        if tailscale_ui:
            self._ui_ingress()
        if lan_host:
            self._lan_ingress(lan_host, tls=lan_tls)
        self._repo_external_secret()
        if self.console_envs:
            self._repo_external_secret(
                id="repo-secret-console",
                name="argocd-repo-tripbot-console",
                url=CONSOLE_REPO_URL,
                sm_key=CONSOLE_REPO_SM_KEY,
            )
        if self.video_pipeline_envs:
            self._repo_external_secret(
                id="repo-secret-video-pipeline",
                name="argocd-repo-video-pipeline",
                url=VIDEO_PIPELINE_REPO_URL,
                sm_key=VIDEO_PIPELINE_REPO_SM_KEY,
            )
        # The dev cluster runs notifications.enabled=false (values.k3d.yml), so it
        # skips the webhook secret too.
        if notifications_secret:
            self._notifications_external_secret()

    # ---- Argo CRs (ApiObject) ----
    def _app_project(
        self,
        *,
        id: str,
        name: str,
        description: str,
        source_repos: list[str],
        namespaces: list[str],
        cluster_resources: list[dict],
    ):
        """One AppProject: the apps assigned to it may only pull from
        `source_repos`, sync into `namespaces`, and create the cluster-scoped
        `cluster_resources` (plus any namespaced kind — already gated to those
        namespaces by `destinations`)."""
        proj = cdk8s.ApiObject(
            self,
            id,
            api_version="argoproj.io/v1alpha1",
            kind="AppProject",
            metadata={"name": name, "namespace": ARGO_NS},
        )
        proj.add_json_patch(
            cdk8s.JsonPatch.add(
                "/spec",
                {
                    "description": description,
                    "sourceRepos": source_repos,
                    "destinations": [
                        {"server": IN_CLUSTER, "namespace": ns} for ns in namespaces
                    ],
                    "clusterResourceWhitelist": cluster_resources,
                    "namespaceResourceWhitelist": [{"group": "*", "kind": "*"}],
                },
            )
        )

    def _application_set(
        self,
        *,
        id: str,
        name: str,
        project: str,
        elements: list[dict],
        app_name_tmpl: str,
        include_tmpl: str,
        prune_disabled: bool,
        dest_ns_tmpl: str = "{{.env}}",
        automated_envs: tuple[str, ...] = (),
        automated_holdouts: tuple[tuple[str, str], ...] = (),
        selfheal: bool = True,
        repo_url: str = REPO_URL,
        target_revision_tmpl: str = TARGET_REVISION,
    ):
        """Emit one ApplicationSet -> one Application per generator element. The
        apps set has one element per (env, component, platform) so each component
        is its own Application reconciling its own dist file; supporting + data
        have one element per env. The data set disables prune so it can never
        delete the database/volumes, even when apps flips to automated sync.

        `automated_envs` turns on continuous reconcile (prune, + selfHeal when
        `selfheal`) for just those envs via a per-element templatePatch — so one
        ApplicationSet can run some envs automated and others manual. Empty = every
        Application stays manual-sync (monitor-only). `automated_holdouts` carves
        (env, app) pairs back OUT of an automated env (prod OBS: a pod-template
        change restarts the live stream, so its deploys stay a deliberate sync).
        `selfheal=False` keeps autosync but stops Argo reverting live drift, so a
        hand-edit sticks — used on the throwaway k3d dev instance."""
        sync_options = [
            "CreateNamespace=false",  # namespaces owned by bootstrap
            "ServerSideApply=true",
        ]  # adopt live objects by name on sync
        if prune_disabled:
            sync_options.append("Prune=false")  # never delete stateful resources

        spec: dict = {
            "project": project,
            "source": {
                "repoURL": repo_url,
                "targetRevision": target_revision_tmpl,
                "path": "cdk8s/dist",
                "directory": {"include": include_tmpl},
            },
            "destination": {"server": IN_CLUSTER, "namespace": dest_ns_tmpl},
            "syncPolicy": {
                # Manual sync by default (no `automated` block) — Argo reports drift
                # but touches nothing. The apps set turns on `automated` per-env via
                # the templatePatch below (AUTOSYNC_ENVS). The DATA unit stays manual
                # + Prune=false forever — that's its safety guarantee.
                "syncOptions": sync_options,
            },
            # ESO's ExternalSecret CRD stamps schema defaults our manifests omit
            # (target.deletionPolicy, and conversionStrategy/decodingStrategy/
            # metadataPolicy/nullBytePolicy under each data[].remoteRef and
            # dataFrom[].extract). They're API-server schema defaults with no
            # field-manager owner, so they can't be waived via managedFieldsManagers
            # and otherwise leave every ExternalSecret perpetually OutOfSync. Ignore
            # exactly those paths so they read Synced. Harmless no-op on the data
            # unit (no ExternalSecrets there).
            "ignoreDifferences": [
                {
                    "group": "external-secrets.io",
                    "kind": "ExternalSecret",
                    "jqPathExpressions": [
                        ".spec.target.deletionPolicy",
                        ".spec.data[]?.remoteRef.conversionStrategy",
                        ".spec.data[]?.remoteRef.decodingStrategy",
                        ".spec.data[]?.remoteRef.metadataPolicy",
                        ".spec.data[]?.remoteRef.nullBytePolicy",
                        ".spec.dataFrom[]?.extract.conversionStrategy",
                        ".spec.dataFrom[]?.extract.decodingStrategy",
                        ".spec.dataFrom[]?.extract.metadataPolicy",
                        ".spec.dataFrom[]?.extract.nullBytePolicy",
                    ],
                },
                # The apiserver defaults apiVersion: v1 / kind: PersistentVolumeClaim
                # onto every StatefulSet volumeClaimTemplate at admission. The k8s
                # schema's embedded-PVC props (KubePersistentVolumeClaimProps) have
                # no apiVersion/kind fields, so cdk8s can't render them — leaving the
                # postgres -data Application perpetually OutOfSync on those two keys.
                # Ignore exactly those paths. No-op on the apps/supporting units.
                {
                    "group": "apps",
                    "kind": "StatefulSet",
                    "jqPathExpressions": [
                        ".spec.volumeClaimTemplates[]?.apiVersion",
                        ".spec.volumeClaimTemplates[]?.kind",
                    ],
                },
            ],
        }
        appset_spec: dict = {
            "goTemplate": True,
            "goTemplateOptions": ["missingkey=error"],
            "generators": [{"list": {"elements": elements}}],
            # Emergency brake: let a manual sync-policy change on a generated
            # Application STICK instead of being stomped back within seconds by
            # this controller. With this, `argocd app set <app> --sync-policy none`
            # (or the UI autosync toggle) durably disables selfHeal on one
            # Application so its workloads can be scaled down by hand. The
            # override survives until a template change regenerates the
            # Application (e.g. re-applying this file), which doubles as the
            # recovery path back to the declared policy.
            "ignoreApplicationDifferences": [{"jsonPointers": ["/spec/syncPolicy"]}],
            "template": {
                "metadata": {"name": app_name_tmpl},
                "spec": spec,
            },
        }
        # Per-env autosync: merge an `automated` block onto only the matching envs'
        # Applications. templatePatch is re-rendered with the same goTemplate, so a
        # non-matching env (or a held-out app) renders an empty patch (a no-op
        # merge) and stays manual.
        if automated_envs:
            test = " ".join(f'(eq .env "{e}")' for e in automated_envs)
            cond = f"or {test}" if len(automated_envs) > 1 else test
            if automated_holdouts:
                clauses = [
                    f'(and (eq .env "{env}") (eq .app "{app}"))'
                    for env, app in automated_holdouts
                ]
                held = f"(or {' '.join(clauses)})" if len(clauses) > 1 else clauses[0]
                cond = f"and ({cond}) (not {held})"
            appset_spec["templatePatch"] = (
                "{{- if " + cond + " }}\n"
                "spec:\n"
                "  syncPolicy:\n"
                "    automated:\n"
                "      prune: true\n"
                f"      selfHeal: {'true' if selfheal else 'false'}\n"
                "{{- end }}\n"
            )
        appset = cdk8s.ApiObject(
            self,
            id,
            api_version="argoproj.io/v1alpha1",
            kind="ApplicationSet",
            metadata={"name": name, "namespace": ARGO_NS},
        )
        appset.add_json_patch(cdk8s.JsonPatch.add("/spec", appset_spec))

    # ---- supporting objects (typed) ----
    def _ui_ingress(self):
        # TLS terminates at the tailnet edge; forwards plain HTTP to
        # argocd-server:80 (chart runs server.insecure). UI at argocd-prod.<tailnet>.
        k8s.KubeIngress(
            self,
            "ui-ingress",
            metadata=k8s.ObjectMeta(name="argocd-server-tailscale", namespace=ARGO_NS),
            spec=k8s.IngressSpec(
                ingress_class_name="tailscale",
                default_backend=k8s.IngressBackend(
                    service=k8s.IngressServiceBackend(
                        name="argocd-server", port=k8s.ServiceBackendPort(name="http")
                    )
                ),
                tls=[k8s.IngressTls(hosts=[TAILNET_HOST])],
            ),
        )

    def _lan_ingress(self, host: str, *, tls: bool = True):
        # LAN-reachable UI at `host` (argocd.<env>.whereisdana.today), the same shape
        # as the apps' traefik Ingress + the traefik dashboard. external-dns
        # publishes the record to the cluster's LAN endpoint. On minipc, cert-manager
        # issues a cert via the route53 ClusterIssuer (the argocd namespace has no
        # namespaced Issuer, so use the cluster-scoped one). The k3d dev cluster runs
        # without TLS (tls=False) — reached at http://<host>:9080. Forwards to
        # argocd-server:80 (the chart runs server.insecure).
        annotations = {"external-dns.alpha.kubernetes.io/hostname": host}
        tls_block = None
        if tls:
            annotations["cert-manager.io/cluster-issuer"] = "letsencrypt-route53"
            tls_block = [k8s.IngressTls(hosts=[host], secret_name="argocd-server-tls")]
        k8s.KubeIngress(
            self,
            "lan-ingress",
            metadata=k8s.ObjectMeta(
                name="argocd-server-traefik",
                namespace=ARGO_NS,
                annotations=annotations,
            ),
            spec=k8s.IngressSpec(
                ingress_class_name="traefik",
                tls=tls_block,
                rules=[
                    k8s.IngressRule(
                        host=host,
                        http=k8s.HttpIngressRuleValue(
                            paths=[
                                k8s.HttpIngressPath(
                                    path="/",
                                    path_type="Prefix",
                                    backend=k8s.IngressBackend(
                                        service=k8s.IngressServiceBackend(
                                            name="argocd-server",
                                            port=k8s.ServiceBackendPort(name="http"),
                                        )
                                    ),
                                )
                            ]
                        ),
                    )
                ],
            ),
        )

    def _notifications_external_secret(self):
        # Webhook credential for the notifications controller (configured in
        # k8s/argo-cd/values.yml, which sets notifications.secret.create=false):
        # ESO materializes argocd-notifications-secret from the shared Discord
        # webhook in SM. The notifier references it as $discord-webhook-url.
        esx.ExternalSecret(
            self,
            "notifications-secret",
            metadata={"name": "argocd-notifications", "namespace": ARGO_NS},
            spec=esx.ExternalSecretSpec(
                refresh_interval="1h",
                secret_store_ref=esx.ExternalSecretSpecSecretStoreRef(
                    name="aws-secretsmanager-cluster",
                    kind=esx.ExternalSecretSpecSecretStoreRefKind.CLUSTER_SECRET_STORE,
                ),
                target=esx.ExternalSecretSpecTarget(
                    name="argocd-notifications-secret",
                    creation_policy=esx.ExternalSecretSpecTargetCreationPolicy.OWNER,
                ),
                data=[
                    esx.ExternalSecretSpecData(
                        secret_key="discord-webhook-url",
                        remote_ref=esx.ExternalSecretSpecDataRemoteRef(
                            key=NOTIFICATIONS_SM_KEY
                        ),
                    )
                ],
            ),
        )

    def _repo_external_secret(
        self,
        id: str = "repo-secret",
        name: str = "argocd-repo-infra",
        url: str = REPO_URL,
        sm_key: str = REPO_SM_KEY,
    ):
        # IaC repo registration: ESO materializes the Argo-recognized `repository`
        # Secret (label argocd.argoproj.io/secret-type: repository) from the deploy
        # key in SM. Reads the cluster-wide platform store. One-time bootstrap per
        # repo: generate a read-only deploy key, add the public half to GitHub,
        # store the private half at the repo's SM key in prod's SM.
        esx.ExternalSecret(
            self,
            id,
            metadata={"name": name, "namespace": ARGO_NS},
            spec=esx.ExternalSecretSpec(
                refresh_interval="1h",
                secret_store_ref=esx.ExternalSecretSpecSecretStoreRef(
                    name="aws-secretsmanager-cluster",
                    kind=esx.ExternalSecretSpecSecretStoreRefKind.CLUSTER_SECRET_STORE,
                ),
                target=esx.ExternalSecretSpecTarget(
                    name=name,
                    creation_policy=esx.ExternalSecretSpecTargetCreationPolicy.OWNER,
                    template=esx.ExternalSecretSpecTargetTemplate(
                        engine_version=esx.ExternalSecretSpecTargetTemplateEngineVersion.V2,
                        metadata=esx.ExternalSecretSpecTargetTemplateMetadata(
                            labels={"argocd.argoproj.io/secret-type": "repository"}
                        ),
                        data={
                            "type": "git",
                            "url": url,
                            "sshPrivateKey": "{{ .sshPrivateKey }}",
                        },
                    ),
                ),
                data=[
                    esx.ExternalSecretSpecData(
                        secret_key="sshPrivateKey",
                        remote_ref=esx.ExternalSecretSpecDataRemoteRef(key=sm_key),
                    )
                ],
            ),
        )
