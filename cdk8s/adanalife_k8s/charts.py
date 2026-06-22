"""Deploy units. Each Chart synthesizes to one file in dist/ and is applied
independently — the per-env SupportingChart / DataChart and PlatformChart per
cluster — so each is its own sync/health unit (one Argo Application) and the
platform stack stays decoupled from any app env.

The tripbot APP workloads (tripbot/vlc/onscreens/obs Deployments + their one-shot
Jobs + identity Secrets) and the dashcam-cv vector-fill workload are no longer
authored here: they moved to the tripbot and video-pipeline repos' cdk8s and Argo
delivers them cross-repo (see constructs/argocd.py). This module keeps only the
platform + stateful units that stay in infra.
"""

from __future__ import annotations

from cdk8s import Chart
from constructs import Construct

from adanalife_k8s.config import EnvConfig
from adanalife_k8s.constructs.dashcam import (
    emit_dashcam_local_pvc,
    emit_dashcam_localize_job,
    emit_dashcam_pv,
    emit_dashcam_pvc,
)
from adanalife_k8s.constructs.arc import Arc
from adanalife_k8s.constructs.postgres import Postgres
from adanalife_k8s.constructs.ups_monitor import UpsMonitor
from adanalife_k8s.eso import secret_store
from adanalife_k8s.supporting import emit_supporting


class SupportingChart(Chart):
    """Per-env namespace supporting resources every stack in the env depends on,
    isolated from the high-churn app workloads: the shared observability
    ExternalSecrets + cert-manager Issuers (emit_supporting). Synced after data,
    before apps. The ESO SecretStore these reference is in DataChart (the
    synced-first unit).

    tripbot's identity-level Secrets (DB creds + twitch/maps/discord) and the
    prod-stream PriorityClass/ResourceQuota are NOT here anymore — they moved to
    the tripbot repo's cdk8s (`<env>-tripbot-identity.k8s.yaml`), delivered by the
    `tripbot-identity` ApplicationSet. The apps reference those Secrets by name.
    """

    def __init__(self, scope: Construct, id: str, *, env: EnvConfig):
        super().__init__(scope, id, namespace=env.namespace or None)
        self.env = env

        # shared observability secrets + cert-manager issuers (eso envs only)
        emit_supporting(self, env)

        # When postgres is isolated in its own namespace, its ESO SecretStore went
        # with it (DataChart) — so the app namespace needs its OWN store for the
        # ExternalSecrets above + in the component charts. (Co-located envs share
        # DataChart's same-namespace store, so this would be a duplicate there.)
        if env.data_isolated and env.secret_source == "eso":
            secret_store(self, "secret-store", namespace=env.namespace or None)
        # The dashcam PVC can't follow postgres into the data namespace — vlc
        # mounts it and PVCs are namespace-local — so when the DB is isolated it
        # lives here in the app namespace. (Co-located envs keep it in DataChart.)
        if env.data_isolated:
            emit_dashcam_pvc(self, env)
            # The node-local corpus cache rides alongside the NFS PVC, same
            # namespace (no-op unless dashcam_local_enabled).
            emit_dashcam_local_pvc(self, env)


class DataChart(Chart):
    """STATEFUL resources for one environment, isolated from the app charts so the
    high-churn stateless apps can't affect them: the postgres StatefulSet (+ its
    PVC/StorageClass, backup CronJob) and the dashcam PVC.

    Applied as its own deploy unit / Argo Application with **prune disabled** —
    so even if one of these vanished from the manifests, the controller would
    never delete the database or volumes. Reclaim policy is Retain on the
    precious PVs (prod postgres → local-path-retain; dashcam → Retain), so the
    bytes survive object deletion regardless. Sync this BEFORE the apps unit
    (it's a dependency: tripbot/vlc need postgres + the dashcam PVC).

    The dashcam *PV* is NOT here — it's host-specific bootstrap infra kept out of
    Argo entirely (see DashcamPVChart). Only the PVC lives here; it binds to the
    out-of-band PV by name.

    Lands in env.data_ns — the app namespace by default (byte-identical render),
    or an isolated namespace (env.data_namespace, e.g. stage-1-data) so a
    `kubectl delete ns <app>` can't take the database. Apps reach it cross-
    namespace via env.postgres_host (an FQDN when isolated).

    The ESO SecretStore is emitted here so this unit is self-sufficient (its
    postgres ExternalSecret doesn't depend on another unit landing the store
    first). When co-located, it doubles as the app namespace's store; when
    isolated, the app namespace gets its own store in SupportingChart, and the
    dashcam PVC moves there too (vlc mounts it — it can't live in the data ns).
    """

    def __init__(self, scope: Construct, id: str, *, env: EnvConfig):
        super().__init__(scope, id, namespace=env.data_ns or None)
        self.env = env

        # --- ESO SecretStore (eso envs only): the postgres ExternalSecret here
        #     references it, so it lives in the same (data) namespace. When the DB
        #     is co-located this is also the app namespace's store (every
        #     ExternalSecret references it); when isolated, the app namespace gets
        #     its own store in SupportingChart. ---
        if env.secret_source == "eso":
            secret_store(self, "secret-store", namespace=env.data_ns or None)

        # --- postgres (StatefulSet; prod adds StorageClass + backup CronJob).
        #     Lands in env.data_ns — the deletion boundary this unit protects. ---
        Postgres(self, env=env)

        # --- dashcam PVC (nfs envs only; no-op on hostPath local/dev). The PV it
        #     binds to is provisioned out-of-band via DashcamPVChart. Mounted by
        #     vlc (namespace-local), so it can only live in the app namespace:
        #     co-located here, but moved to SupportingChart when the DB is isolated
        #     in a different namespace. ---
        if not env.data_isolated:
            emit_dashcam_pvc(self, env)
            # The node-local corpus cache rides alongside the NFS PVC, same
            # namespace (no-op unless dashcam_local_enabled).
            emit_dashcam_local_pvc(self, env)


class DashcamPVChart(Chart):
    """The dashcam NFS PersistentVolume (cluster-scoped) — host-specific bootstrap
    infra deliberately kept OUT of Argo. Synthed to its own
    dist/<env>-dashcam-pv.k8s.yaml, which no ApplicationSet includes (the apps set
    matches `<env>-<component>-<platform>.k8s.yaml`; supporting/data match their
    own per-env files), and provisioned once per
    cluster via `task k8s:<env>:dashcam-pv` with the real NFS coords from the
    gitignored cdk8s/dashcam-nfs.local.env. The committed golden carries
    placeholders. The matching PVC lives in DataChart (Argo binds it by name).
    """

    def __init__(self, scope: Construct, id: str, *, env: EnvConfig):
        super().__init__(scope, id)  # cluster-scoped — no namespace
        emit_dashcam_pv(self, env)


class DashcamLocalizeChart(Chart):
    """The one-shot Job that copies the NFS corpus onto the node-local cache PVC —
    host-specific (carries the NFS coords), so it's kept OUT of Argo in its own
    dist/<env>-dashcam-localize.k8s.yaml (globbed by no ApplicationSet, same as
    DashcamPVChart) and applied on demand via `task k8s:<env>:dashcam-localize` with
    the real coords injected at synth. Rendered only when dashcam_local_enabled, so
    it never lands in dist for an env that hasn't adopted local serving."""

    def __init__(self, scope: Construct, id: str, *, env: EnvConfig):
        super().__init__(scope, id, namespace=env.namespace or None)
        emit_dashcam_localize_job(self, env)


class UpsMonitorChart(Chart):
    """The observe-only NUT-client UPS monitor — a cluster-singleton (one minipc,
    one UPS) in its own `ups` namespace. Env-agnostic, so it's authored once and
    synthed to dist/ups-monitor.k8s.yaml, delivered by a dedicated minipc-only
    Argo Application (see constructs/argocd.py — gated off the k3d dev instance,
    which can't reach the Synology NUT server). See constructs/ups_monitor.py for
    the observe-only-now / arm-later staging."""

    def __init__(self, scope: Construct, id: str):
        super().__init__(scope, id)
        UpsMonitor(self)


class ArcChart(Chart):
    """ARC supporting resources (namespaces + runner ResourceQuota + GitHub App
    ExternalSecret) — a cluster-singleton, env-agnostic, synthed to
    dist/arc.k8s.yaml and delivered by a minipc-only Argo Application (gated off
    the k3d dev instance, which has no rpi5 — see constructs/argocd.py). The ARC
    Helm charts themselves are Argo Applications in the platform stack
    (helm_platform.arc_components); see constructs/arc.py for the split."""

    def __init__(self, scope: Construct, id: str):
        super().__init__(scope, id)
        Arc(self)


class ArgoCDChart(Chart):
    """Argo CD GitOps config (AppProject + ApplicationSets + UI Ingress + repo
    ExternalSecret) — the objects that drive the controller. Applied after the
    Argo install (the Helm chart in PlatformChart). Offline + deterministic, so
    it's committed to dist/ + golden-gated like the app units. Cluster-level
    (env-agnostic — it lists the envs internally)."""

    def __init__(self, scope: Construct, id: str, **argo_kwargs):
        super().__init__(scope, id)
        from adanalife_k8s.constructs.argocd import ArgoCD

        # argo_kwargs select the cluster's env-set + UI mode: defaults give the
        # minipc instance; main.py passes the k3d dev variant (development, no UI).
        ArgoCD(self, **argo_kwargs)


class PlatformArgoChart(Chart):
    """Argo CD Applications that deliver the platform Helm stack natively (one
    multi-source Helm Application per release, version-pinned, values from the
    in-repo k8s/*/values.yml). Offline — just Application objects, no rendered
    charts — so it's committed + golden-gated like the app units. The actual chart
    rendering happens in-cluster (Argo runs helm template), not at synth. See
    constructs/argo_platform.py. Cluster-level (minipc; env-agnostic)."""

    def __init__(self, scope: Construct, id: str):
        super().__init__(scope, id)
        from adanalife_k8s.constructs.argo_platform import ArgoPlatform

        ArgoPlatform(self)
