"""Argo CD GitOps config, authored in cdk8s (was plain YAML under gitops/ +
k8s/argo-cd/). Synthesizes to dist/argocd.k8s.yaml — a committed, golden-gated
deploy unit applied after the Argo install (which is the Helm chart in
PlatformChart). Argo CD itself is the controller; these are the objects that tell
it what to watch:

  * AppProject (tripbot) — a restrictive project: only the infra repo, only the
    in-cluster prod-1/stage-1 namespaces, only the cluster-scoped kinds the apps
    actually use (PV, StorageClass). Caps the blast radius vs the wide-open
    `default` project. (Reserve "infra"/"platform" naming for shared cluster
    infrastructure; these are tripbot-project workloads.)
  * Three ApplicationSets — `tripbot-apps` (one Application per
    <env>-<component>-<platform>, so each component is its own sync/health/URL),
    `tripbot-supporting` and `tripbot-data` (one per env). Each reconciles its own
    cdk8s/dist file. MONITOR-ONLY: manual sync (no automated prune/selfHeal), so
    Argo reports drift but changes nothing until you sync. ignoreDifferences keeps
    ESO's CRD schema-default fields out of the diff so ExternalSecrets read Synced.
  * tailscale Ingress — the UI at argocd-prod.<tailnet>.ts.net.
  * traefik Ingress — the same UI at argocd.prod.whereisdana.today, published by
    external-dns to the cluster's LAN endpoint (reachable on-LAN directly, off-LAN
    via the tailscale subnet route). cert-manager issues the cert via the route53
    ClusterIssuer. Mirrors the apps' traefik+tailscale dual exposure.
  * repo ExternalSecret — IaC repo registration: ESO materializes the
    Argo-recognized `repository` Secret from a read-only deploy key in SM.

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
# The project governs all the tripbot-project workloads (apps + supporting + data,
# and later the cross-repo console/helix). "infra"/"platform" naming is reserved
# for shared cluster infrastructure, never the tripbot app workloads.
PROJECT = "tripbot"
IN_CLUSTER = "https://kubernetes.default.svc"
# minipc envs Argo runs in-cluster against (development is on the bees cluster —
# needs separate registration, a follow-up).
ENVS = ("prod-1", "stage-1")
# Envs migrated to the per-component topology. Stage cut over first; prod now
# joins at its own wipe — the per-component topology AND the postgres data-
# namespace move land together in one prod wipe (config.prod-1.data_namespace).
# The live legacy adanalife-* ApplicationSets + AppProject are deleted by hand
# during that wipe (they collide with the new sets on the shared `{env}-data`
# Application name, so they can't coexist) — see the prod cutover runbook.
CUTOVER_ENVS = ENVS
# Envs whose *apps* run automated (prune + selfHeal) — a merged dist/ change
# deploys itself. Applied per-env via a templatePatch on the apps ApplicationSet,
# so the rest stay manual. stage-1 leads; prod-1 is held out deliberately until
# we're confident. The DATA units NEVER autosync (Prune=false is their guarantee);
# supporting stays manual too — only the apps set reads this.
AUTOSYNC_ENVS = ("stage-1",)
TAILNET_HOST = "argocd-prod"  # -> argocd-prod.<tailnet>.ts.net
# LAN-reachable UI host published by external-dns to the cluster's LAN endpoint.
# Argo is a prod-only install (it governs both prod-1 + stage-1), so the host
# lives under the prod subdomain alongside the apps (vlc-twitch.prod...) and the
# traefik dashboard.
LAN_HOST = "argocd.prod.whereisdana.today"
REPO_SM_KEY = "k8s/argocd/repo-ssh-key"


def _data_ns(env_name: str) -> str:
    """The namespace the data unit deploys into for an env — env.data_ns (its own
    isolated namespace when set, else the app namespace). Lazy import avoids the
    charts.py <-> argocd.py cycle."""
    from adanalife_k8s.config import load_env

    return load_env(env_name).data_ns


def _project_namespaces() -> list[str]:
    """Every namespace an Application in this project may target: the app
    namespaces plus any isolated data namespace (e.g. stage-1-data). Drives the
    AppProject `destinations` allowlist — an Application can't sync into a
    namespace the project doesn't permit."""
    seen: list[str] = list(ENVS)
    for e in CUTOVER_ENVS:
        ns = _data_ns(e)
        if ns not in seen:
            seen.append(ns)
    return seen


def _app_elements() -> list[dict]:
    """The per-component ApplicationSet elements: one {env, app} per
    (env, platform, component), where app = "<component>-<platform>". Computed
    from the SAME source emit_app_charts loops over (ENVS × env.platforms ×
    COMPONENTS), so the generated Applications can't drift from the synthed files
    — adding a platform extends both. Lazy imports avoid an import cycle with
    charts.py (which imports this module's ArgoCD)."""
    from adanalife_k8s.charts import COMPONENTS
    from adanalife_k8s.config import load_env

    return [
        {"env": env_name, "app": f"{comp}-{platform}"}
        for env_name in CUTOVER_ENVS
        for platform in load_env(env_name).platforms
        for comp in COMPONENTS
    ]


class ArgoCD(Construct):
    def __init__(self, scope: Construct, id: str = "argocd"):
        super().__init__(scope, id)

        self._app_project()
        # Three ApplicationSets, one Application each per unit. The apps set is
        # per-COMPONENT (one Application per <env>-<component>-<platform> →
        # cdk8s/dist/<env>-<component>-<platform>.k8s.yaml), so each component is
        # its own sync/health/URL. supporting + data are per-env. Data never
        # prunes, so an app deploy can't delete the database or volumes.
        self._application_set(
            id="appset-apps",
            name="tripbot-apps",
            elements=_app_elements(),
            app_name_tmpl="{{.env}}-{{.app}}",
            include_tmpl="{{.env}}-{{.app}}.k8s.yaml",
            prune_disabled=False,
            automated_envs=AUTOSYNC_ENVS,
        )
        self._application_set(
            id="appset-supporting",
            name="tripbot-supporting",
            elements=[{"env": e} for e in CUTOVER_ENVS],
            app_name_tmpl="{{.env}}-supporting",
            include_tmpl="{{.env}}-supporting.k8s.yaml",
            prune_disabled=False,
        )
        self._application_set(
            id="appset-data",
            name="tripbot-data",
            # The data unit deploys into env.data_ns (its own namespace when the DB
            # is isolated, e.g. stage-1-data), not the app namespace — so carry the
            # target namespace in each element rather than deriving it from env.
            elements=[{"env": e, "ns": _data_ns(e)} for e in CUTOVER_ENVS],
            app_name_tmpl="{{.env}}-data",
            include_tmpl="{{.env}}-data.k8s.yaml",
            dest_ns_tmpl="{{.ns}}",
            # NEVER prune the stateful unit.
            prune_disabled=True,
        )
        self._ui_ingress()
        self._lan_ingress()
        self._repo_external_secret()

    # ---- Argo CRs (ApiObject) ----
    def _app_project(self):
        proj = cdk8s.ApiObject(
            self,
            "project",
            api_version="argoproj.io/v1alpha1",
            kind="AppProject",
            metadata={"name": PROJECT, "namespace": ARGO_NS},
        )
        proj.add_json_patch(
            cdk8s.JsonPatch.add(
                "/spec",
                {
                    "description": "adanalife app workloads synthesized by cdk8s",
                    "sourceRepos": [REPO_URL],
                    "destinations": [
                        {"server": IN_CLUSTER, "namespace": ns}
                        for ns in _project_namespaces()
                    ],
                    # The apps' cluster-scoped objects — nothing else may be created.
                    "clusterResourceWhitelist": [
                        {"group": "", "kind": "PersistentVolume"},
                        {"group": "storage.k8s.io", "kind": "StorageClass"},
                    ],
                    # Any namespaced kind is fine (it's already gated to the two namespaces
                    # by `destinations`).
                    "namespaceResourceWhitelist": [{"group": "*", "kind": "*"}],
                },
            )
        )

    def _application_set(
        self,
        *,
        id: str,
        name: str,
        elements: list[dict],
        app_name_tmpl: str,
        include_tmpl: str,
        prune_disabled: bool,
        dest_ns_tmpl: str = "{{.env}}",
        automated_envs: tuple[str, ...] = (),
    ):
        """Emit one ApplicationSet -> one Application per generator element. The
        apps set has one element per (env, component, platform) so each component
        is its own Application reconciling its own dist file; supporting + data
        have one element per env. The data set disables prune so it can never
        delete the database/volumes, even when apps flips to automated sync.

        `automated_envs` turns on continuous reconcile (prune + selfHeal) for just
        those envs via a per-element templatePatch — so one ApplicationSet can run
        some envs automated (stage-1) and others manual (prod-1). Empty = every
        Application stays manual-sync (monitor-only)."""
        sync_options = [
            "CreateNamespace=false",  # namespaces owned by bootstrap
            "ServerSideApply=true",
        ]  # adopt live objects by name on sync
        if prune_disabled:
            sync_options.append("Prune=false")  # never delete stateful resources

        spec: dict = {
            "project": PROJECT,
            "source": {
                "repoURL": REPO_URL,
                "targetRevision": TARGET_REVISION,
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
            "template": {
                "metadata": {"name": app_name_tmpl},
                "spec": spec,
            },
        }
        # Per-env autosync: merge an `automated` block onto only the matching envs'
        # Applications. templatePatch is re-rendered with the same goTemplate, so a
        # non-matching env renders an empty patch (a no-op merge) and stays manual.
        if automated_envs:
            test = " ".join(f'(eq .env "{e}")' for e in automated_envs)
            cond = f"or {test}" if len(automated_envs) > 1 else test
            appset_spec["templatePatch"] = (
                "{{- if " + cond + " }}\n"
                "spec:\n"
                "  syncPolicy:\n"
                "    automated:\n"
                "      prune: true\n"
                "      selfHeal: true\n"
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

    def _lan_ingress(self):
        # LAN-reachable UI at argocd.prod.whereisdana.today, the same shape as the
        # apps' traefik Ingress + the traefik dashboard. external-dns publishes the
        # record (to the cluster's LAN endpoint); cert-manager issues the cert via
        # the route53 ClusterIssuer (the argocd namespace has no namespaced Issuer,
        # so use the cluster-scoped one, like the kube-system dashboard Ingress).
        # Forwards to argocd-server:80 (the chart runs server.insecure, TLS
        # terminated at traefik).
        k8s.KubeIngress(
            self,
            "lan-ingress",
            metadata=k8s.ObjectMeta(
                name="argocd-server-traefik",
                namespace=ARGO_NS,
                annotations={
                    "external-dns.alpha.kubernetes.io/hostname": LAN_HOST,
                    "cert-manager.io/cluster-issuer": "letsencrypt-route53",
                },
            ),
            spec=k8s.IngressSpec(
                ingress_class_name="traefik",
                tls=[k8s.IngressTls(hosts=[LAN_HOST], secret_name="argocd-server-tls")],
                rules=[
                    k8s.IngressRule(
                        host=LAN_HOST,
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

    def _repo_external_secret(self):
        # IaC repo registration: ESO materializes the Argo-recognized `repository`
        # Secret (label argocd.argoproj.io/secret-type: repository) from the deploy
        # key in SM. Reads the cluster-wide platform store. One-time bootstrap:
        # generate a read-only deploy key, add the public half to GitHub, store the
        # private half at k8s/argocd/repo-ssh-key in prod's SM.
        esx.ExternalSecret(
            self,
            "repo-secret",
            metadata={"name": "argocd-repo-infra", "namespace": ARGO_NS},
            spec=esx.ExternalSecretSpec(
                refresh_interval="1h",
                secret_store_ref=esx.ExternalSecretSpecSecretStoreRef(
                    name="aws-secretsmanager-cluster",
                    kind=esx.ExternalSecretSpecSecretStoreRefKind.CLUSTER_SECRET_STORE,
                ),
                target=esx.ExternalSecretSpecTarget(
                    name="argocd-repo-infra",
                    creation_policy=esx.ExternalSecretSpecTargetCreationPolicy.OWNER,
                    template=esx.ExternalSecretSpecTargetTemplate(
                        engine_version=esx.ExternalSecretSpecTargetTemplateEngineVersion.V2,
                        metadata=esx.ExternalSecretSpecTargetTemplateMetadata(
                            labels={"argocd.argoproj.io/secret-type": "repository"}
                        ),
                        data={
                            "type": "git",
                            "url": REPO_URL,
                            "sshPrivateKey": "{{ .sshPrivateKey }}",
                        },
                    ),
                ),
                data=[
                    esx.ExternalSecretSpecData(
                        secret_key="sshPrivateKey",
                        remote_ref=esx.ExternalSecretSpecDataRemoteRef(key=REPO_SM_KEY),
                    )
                ],
            ),
        )
