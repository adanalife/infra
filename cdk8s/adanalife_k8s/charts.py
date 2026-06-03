"""Deploy units. Each Chart synthesizes to one file in dist/ and is applied
independently — one per (component, platform) for the apps (emit_app_charts),
plus per-env SupportingChart / DataChart / JobsChart, and PlatformChart per
cluster — so every component is its own sync/health unit (one Argo Application,
one URL) and the platform stack stays decoupled from any app env.
"""

from __future__ import annotations

from cdk8s import Chart
from constructs import Construct

from adanalife_k8s.config import EnvConfig
from adanalife_k8s.constructs.dashcam_cv import DashcamCV, DashcamCVJobs
from adanalife_k8s.eso import secret_store
from adanalife_k8s.constructs.obs import ObsInstance
from adanalife_k8s.constructs.onscreens import OnscreensServer
from adanalife_k8s.constructs.postgres import Postgres
from adanalife_k8s.constructs.tripbot import Tripbot, emit_identity_secrets
from adanalife_k8s.constructs.vlc import (
    VlcServer,
    emit_dashcam_pv,
    emit_dashcam_pvc,
)
from adanalife_k8s.supporting import emit_supporting


# Stateless app components that each get their own Chart (→ one dist file + one
# Argo Application) per (env, platform). obs is emitted separately for its
# streaming args. Keep this list in sync with the contract's per-platform service
# keys; naming.app_name maps (component, platform) -> the Service name.
COMPONENTS = ("tripbot", "vlc", "onscreens", "obs")
_SIMPLE_COMPONENTS = (
    ("tripbot", Tripbot),
    ("vlc", VlcServer),
    ("onscreens", OnscreensServer),
)


def emit_app_charts(scope: Construct, env: EnvConfig) -> None:
    """One Chart per (component, platform) — each synthesizes to its own
    `dist/<env>-<component>-<platform>.k8s.yaml`, so every component is an
    independent Argo Application (one sync/health/URL). The supporting + stateful
    + one-shot units stay separate (SupportingChart / DataChart / JobsChart).
    """
    ns = env.namespace or None
    for platform in env.platforms:
        for comp, ctor in _SIMPLE_COMPONENTS:
            chart = Chart(scope, f"{env.name}-{comp}-{platform}", namespace=ns)
            ctor(chart, platform, env=env)

        # OBS — its own chart. twitch streams by default in prod (ESO stream-key);
        # everything else boots idle until toggled on. youtube carries
        # STREAM_PLATFORM=youtube.
        streaming = platform == "twitch" and env.name == "prod-1"
        obs_chart = Chart(scope, f"{env.name}-obs-{platform}", namespace=ns)
        ObsInstance(
            obs_chart,
            platform,
            env=env,
            streaming=streaming,
            stream_key_sm=f"k8s/obs/{platform}-stream-key" if streaming else None,
            extra_config={"STREAM_PLATFORM": "youtube"}
            if platform == "youtube"
            else None,
        )


class SupportingChart(Chart):
    """Per-env namespace supporting resources every stack in the env depends on,
    isolated from the high-churn app workloads: the shared observability
    ExternalSecrets + cert-manager Issuers (emit_supporting), plus tripbot's
    identity-level Secrets (DB creds + twitch/maps/discord — one bot identity, one
    DB, shared by every platform stack). Synced after data, before apps. The ESO
    SecretStore these reference is in DataChart (the synced-first unit).
    """

    def __init__(self, scope: Construct, id: str, *, env: EnvConfig):
        super().__init__(scope, id, namespace=env.namespace or None)
        self.env = env

        # shared observability secrets + cert-manager issuers (eso envs only)
        emit_supporting(self, env)
        # tripbot identity Secrets (every env — local Secret or DB ES + app ES)
        emit_identity_secrets(self, env)


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

    The ESO SecretStore is emitted here (not the app charts) so this unit is fully
    self-sufficient: postgres-credentials no longer depends on the apps unit
    landing the store first. apps' ExternalSecrets reference the same store,
    synced after data — matching the documented data-before-apps order.
    """

    def __init__(self, scope: Construct, id: str, *, env: EnvConfig):
        super().__init__(scope, id, namespace=env.namespace or None)
        self.env = env

        # --- ESO SecretStore (eso envs only): foundational, every ExternalSecret
        #     in BOTH units references it, so it lives in the synced-first unit ---
        if env.secret_source == "eso":
            secret_store(self, "secret-store", namespace=env.namespace or None)

        # --- postgres (StatefulSet; prod adds StorageClass + backup CronJob) ---
        Postgres(self, env=env)

        # --- dashcam PVC (nfs envs only; no-op on hostPath local/dev). The PV it
        #     binds to is provisioned out-of-band via DashcamPVChart. ---
        emit_dashcam_pvc(self, env)


class DashcamPVChart(Chart):
    """The dashcam NFS PersistentVolume (cluster-scoped) — host-specific bootstrap
    infra deliberately kept OUT of Argo. Synthed to its own
    dist/<env>-dashcam-pv.k8s.yaml, which neither the apps nor data ApplicationSet
    globs (they match `<env>-{apps,data}.k8s.yaml`), and provisioned once per
    cluster via `task k8s:<env>:dashcam-pv` with the real NFS coords from the
    gitignored cdk8s/dashcam-nfs.local.env. The committed golden carries
    placeholders. The matching PVC lives in DataChart (Argo binds it by name).
    """

    def __init__(self, scope: Construct, id: str, *, env: EnvConfig):
        super().__init__(scope, id)  # cluster-scoped — no namespace
        emit_dashcam_pv(self, env)


class DashcamCVChart(Chart):
    """The PERSISTENT dashcam-cv vector-fill workload (PriorityClass + models PVC
    + the suspended fill CronJob). A separate deploy unit because it was never in
    the env umbrellas — a background batch job staged via its own task,
    currently stage-only. The one-shot ops Jobs live in DashcamCVJobsChart.
    """

    def __init__(self, scope: Construct, id: str, *, env: EnvConfig):
        super().__init__(scope, id, namespace=env.namespace or None)
        DashcamCV(self, env=env)


class DashcamCVJobsChart(Chart):
    """The on-demand dashcam-cv one-shot Jobs (fill-once / find / stats). Their
    own deploy unit so a normal `apply` of DashcamCVChart never re-runs them
    (running a Job on each reconcile would be wrong — same split as JobsChart).
    Run via the per-job tasks; depends on DashcamCVChart's PVC + PriorityClass.
    """

    def __init__(self, scope: Construct, id: str, *, env: EnvConfig):
        super().__init__(scope, id, namespace=env.namespace or None)
        DashcamCVJobs(self, env=env)


class JobsChart(Chart):
    """tripbot one-shot Jobs (auth-bootstrap bot+broadcaster, seed). Applied
    per-env via `task tripbot:<env>:auth:bootstrap` / `:seed`, never on a normal
    apply (running a seed/auth job on every reconcile would be wrong)."""

    def __init__(self, scope: Construct, id: str, *, env: EnvConfig):
        super().__init__(scope, id, namespace=env.namespace or None)
        from adanalife_k8s.constructs.tripbot import emit_jobs

        emit_jobs(self, env)


class ArgoCDChart(Chart):
    """Argo CD GitOps config (AppProject + ApplicationSets + UI Ingress + repo
    ExternalSecret) — the objects that drive the controller. Applied after the
    Argo install (the Helm chart in PlatformChart). Offline + deterministic, so
    it's committed to dist/ + golden-gated like the app units. Cluster-level
    (env-agnostic — it lists the envs internally)."""

    def __init__(self, scope: Construct, id: str):
        super().__init__(scope, id)
        from adanalife_k8s.constructs.argocd import ArgoCD

        ArgoCD(self)
