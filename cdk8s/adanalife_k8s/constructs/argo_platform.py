"""Argo CD Applications for the platform Helm stack (Argo-native delivery).

Instead of cdk8s pre-rendering the upstream charts (the cdk8s.Helm path in
`helm_platform.PlatformChart`) or the imperative `helm upgrade --install` in
`task k8s:<env>:platform:up`, each platform Helm release becomes an Argo
**Application with a multi-source Helm source**: the upstream chart (version
pinned from `helm_platform.VERSIONS`) plus the in-repo `k8s/<component>/values*.yml`
pulled via a `$values` ref. No rendered charts land in git — just these small
Application objects. Synthesized to `dist/platform-argo.k8s.yaml` (offline, so it's
committed + golden-gated like the app units).

Scope (minipc only — development is on the k3d cluster, with its own Argo):
  * cluster-scoped releases (ESO, cert-manager, node-exporter, victoria-metrics,
    k8s-monitoring, tailscale-operator) — installed once; values from prod-1
    (stage rides prod's cluster-scoped platform, per stage-prod-cotenancy).
  * per-env releases (NATS) — one Application per env namespace, for prod-1 + stage-1.

Excluded — not Argo-manageable (`HelmComponent.argo = False`):
  * **cilium** (the CNI Argo itself rides on) and **argo-cd** (managing its own
    install) — the bootstrap floor.
  * **traefik** + **external-dns** — host-coupled: traefik's ingressEndpoint.ip and
    external-dns's --default-targets are the node's discovered InternalIP, written to
    gitignored values.local.yml at bootstrap (not git-declarable; prod's differs from
    the committed lan_ip). external-dns also carries --force-default-targets in that
    same gitignored arg list. Argo-rendering them from committed values would force
    the wrong target / drop the flag on adoption, so they stay task-installed.

The kustomize-only platform bits (local-path-provisioner, intel-gpu/xpu, ESO
cluster-store, cert-manager ClusterIssuers) are out of scope here too — a later
kustomize-source pass.

**MONITOR-ONLY.** Manual sync; adoption of the live helm releases is deliberate
and rehearsed on stage first — see `gitops/README.md`. The `platform` AppProject is
intentionally broad (all namespaces, all cluster kinds) because installing the
platform means creating CRDs / ClusterRoles / webhooks; it's separate from the
restrictive `tripbot` app project.
"""

from __future__ import annotations

import cdk8s
from constructs import Construct

from adanalife_k8s.config import load_env
from adanalife_k8s.constructs.argocd import (
    ARGO_NS,
    IN_CLUSTER,
    REPO_URL,
    TARGET_REVISION,
)
from adanalife_k8s.helm_platform import (
    HelmComponent,
    REPOS,
    VERSIONS,
    cluster_components,
    env_components,
)

PROJECT = "platform"
# Envs whose per-env platform charts (external-dns, NATS) Argo manages. minipc only
# — development is on the k3d cluster, which runs its own separate Argo install.
PLATFORM_ENVS = ("prod-1", "stage-1")
# Cluster-scoped platform releases install once with prod-1's values (stage rides
# prod's cluster-scoped platform — see stage-prod-cotenancy).
CLUSTER_VALUES_ENV = "prod-1"


class ArgoPlatform(Construct):
    def __init__(self, scope: Construct, id: str = "argo-platform"):
        super().__init__(scope, id)
        self._project()

        # Cluster-scoped releases (one install for the whole minipc), skipping the
        # bootstrap floor (cilium / argo-cd, argo=False).
        for comp in cluster_components("minipc", load_env(CLUSTER_VALUES_ENV)):
            if comp.argo:
                self._application(comp.release, comp, comp.namespace)

        # Per-env releases — name-qualified by env so prod-1/stage-1 don't collide
        # on the Application name. Skips the non-Argo-manageable ones (external-dns:
        # its --default-targets is a host-discovered node IP in gitignored
        # values.local.yml), leaving NATS.
        for env_name in PLATFORM_ENVS:
            for comp in env_components(load_env(env_name)):
                if comp.argo:
                    self._application(f"{env_name}-{comp.chart}", comp, comp.namespace)

    def _project(self):
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
                    "description": "shared cluster platform (Helm) reconciled by Argo CD",
                    # The infra repo (values via $values) + every upstream chart repo.
                    "sourceRepos": [REPO_URL, *sorted(set(REPOS.values()))],
                    # The platform spans many namespaces; gate to in-cluster only.
                    "destinations": [{"server": IN_CLUSTER, "namespace": "*"}],
                    # Installing platform charts creates CRDs / ClusterRoles / webhooks.
                    "clusterResourceWhitelist": [{"group": "*", "kind": "*"}],
                    "namespaceResourceWhitelist": [{"group": "*", "kind": "*"}],
                },
            )
        )

    def _application(self, name: str, comp: HelmComponent, dest_ns: str):
        helm: dict = {"releaseName": comp.release}
        if comp.value_files:
            # $values resolves to the infra repo root (the second source below), so
            # the in-repo value files are referenced verbatim — no values rewrite.
            helm["valueFiles"] = [f"$values/k8s/{vf}" for vf in comp.value_files]
        if comp.values:
            # Inline overrides (LAN IP, --default-targets) as structured values —
            # applied after valueFiles, matching the cdk8s.Helm `-f ... --values`.
            helm["valuesObject"] = comp.values

        chart_source = {
            "repoURL": REPOS[comp.repo_key],
            "chart": comp.chart,
            "targetRevision": VERSIONS[comp.version_key],
            "helm": helm,
        }
        values_source = {
            "repoURL": REPO_URL,
            "targetRevision": TARGET_REVISION,
            "ref": "values",
        }

        app = cdk8s.ApiObject(
            self,
            name,
            api_version="argoproj.io/v1alpha1",
            kind="Application",
            metadata={"name": name, "namespace": ARGO_NS},
        )
        app.add_json_patch(
            cdk8s.JsonPatch.add(
                "/spec",
                {
                    "project": PROJECT,
                    "sources": [chart_source, values_source],
                    "destination": {"server": IN_CLUSTER, "namespace": dest_ns},
                    "syncPolicy": {
                        # MONITOR-ONLY: manual sync. CreateNamespace so Argo owns the
                        # platform namespaces on a fresh cluster; ServerSideApply
                        # because cert-manager's CRDs exceed the apply annotation cap.
                        "syncOptions": [
                            "CreateNamespace=true",
                            "ServerSideApply=true",
                        ],
                    },
                    # The apiserver defaults apiVersion: v1 / kind:
                    # PersistentVolumeClaim onto every StatefulSet volumeClaimTemplate
                    # at admission; the chart-rendered manifest omits them, so a
                    # StatefulSet-bearing release (NATS, with its JetStream PVC) reads
                    # perpetually OutOfSync on those two keys. Ignore exactly those
                    # paths (same as the tripbot-data app set's postgres handling).
                    # No-op on the non-StatefulSet releases.
                    "ignoreDifferences": [
                        {
                            "group": "apps",
                            "kind": "StatefulSet",
                            "jqPathExpressions": [
                                ".spec.volumeClaimTemplates[]?.apiVersion",
                                ".spec.volumeClaimTemplates[]?.kind",
                            ],
                        },
                    ],
                },
            )
        )
