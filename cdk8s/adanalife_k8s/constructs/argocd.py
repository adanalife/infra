"""Argo CD GitOps config, authored in cdk8s (was plain YAML under gitops/ +
k8s/argo-cd/). Synthesizes to dist/argocd.k8s.yaml — a committed, golden-gated
deploy unit applied after the Argo install (which is the Helm chart in
PlatformChart). Argo CD itself is the controller; these are the objects that tell
it what to watch:

  * AppProject (adanalife-apps) — a restrictive project: only the infra repo, only
    the in-cluster prod-1/stage-1 namespaces, only the cluster-scoped kinds the
    apps actually use (PV, StorageClass). Caps the blast radius vs the wide-open
    `default` project.
  * ApplicationSet — one Application per minipc env reconciling
    cdk8s/dist/<env>-apps.k8s.yaml. MONITOR-ONLY: manual sync (no automated
    prune/selfHeal), so Argo reports drift but changes nothing until you sync.
    ignoreDifferences keeps the dashcam PV's host-specific NFS coords out of the
    diff (they're placeholders in git, set out-of-band live).
  * tailscale Ingress — the UI at argocd-prod.<tailnet>.ts.net.
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
PROJECT = "adanalife-apps"
IN_CLUSTER = "https://kubernetes.default.svc"
# minipc envs Argo runs in-cluster against (development is on the bees cluster —
# needs separate registration, a follow-up).
ENVS = ("prod-1", "stage-1")
TAILNET_HOST = "argocd-prod"  # -> argocd-prod.<tailnet>.ts.net
REPO_SM_KEY = "k8s/argocd/repo-ssh-key"


class ArgoCD(Construct):
    def __init__(self, scope: Construct, id: str = "argocd"):
        super().__init__(scope, id)

        self._app_project()
        # Two ApplicationSets: the stateless apps and the stateful data. They get
        # different sync policies — that's the whole point of the split. Data
        # never prunes, so an app deploy can't delete the database or volumes.
        self._application_set(
            unit="apps",
            id="appset-apps",
            # apps create no cluster-scoped objects now; nothing to ignore.
            ignore_pv=False,
            prune_disabled=False,
        )
        self._application_set(
            unit="data",
            id="appset-data",
            # the dashcam PV ships NFS placeholders (host-specific) — ignore them;
            # and NEVER prune the stateful unit.
            ignore_pv=True,
            prune_disabled=True,
        )
        self._ui_ingress()
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
                        {"server": IN_CLUSTER, "namespace": e} for e in ENVS
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
        self, *, unit: str, id: str, ignore_pv: bool, prune_disabled: bool
    ):
        """Emit one ApplicationSet -> one Application per env reconciling
        `dist/<env>-<unit>.k8s.yaml`. `unit` is "apps" (stateless) or "data"
        (stateful). The data unit disables prune so it can never delete the
        database/volumes, even when apps later flips to automated sync."""
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
                "directory": {"include": f"{{{{.env}}}}-{unit}.k8s.yaml"},
            },
            "destination": {"server": IN_CLUSTER, "namespace": "{{.env}}"},
            "syncPolicy": {
                # MONITOR-ONLY: no `automated` block, so manual sync. For the apps
                # unit, enable continuous reconcile post-cutover with
                # "automated": {"prune": True, "selfHeal": True}. Leave the DATA
                # unit manual + Prune=false forever — that's its safety guarantee.
                "syncOptions": sync_options,
            },
        }
        if ignore_pv:
            # The dashcam PV ships NFS placeholders in git (host-specific, set
            # out-of-band) — don't flag it as drift.
            spec["ignoreDifferences"] = [
                {
                    "group": "",
                    "kind": "PersistentVolume",
                    "jsonPointers": ["/spec/nfs/server", "/spec/nfs/path"],
                }
            ]

        appset = cdk8s.ApiObject(
            self,
            id,
            api_version="argoproj.io/v1alpha1",
            kind="ApplicationSet",
            metadata={"name": f"adanalife-{unit}", "namespace": ARGO_NS},
        )
        appset.add_json_patch(
            cdk8s.JsonPatch.add(
                "/spec",
                {
                    "goTemplate": True,
                    "goTemplateOptions": ["missingkey=error"],
                    "generators": [{"list": {"elements": [{"env": e} for e in ENVS]}}],
                    "template": {
                        "metadata": {"name": f"{{{{.env}}}}-{unit}"},
                        "spec": spec,
                    },
                },
            )
        )

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
