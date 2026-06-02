"""Deploy units. Each Chart synthesizes to one file in dist/ and is applied
independently — `AppsChart` per env, `PlatformChart` per cluster (later) — so
the platform stack stays decoupled from any app env.
"""
from __future__ import annotations

from cdk8s import Chart
from constructs import Construct

from adanalife_k8s.config import EnvConfig
from adanalife_k8s.constructs.dashcam_cv import DashcamCV
from adanalife_k8s.constructs.obs import ObsInstance
from adanalife_k8s.constructs.onscreens import OnscreensServer
from adanalife_k8s.constructs.postgres import Postgres
from adanalife_k8s.constructs.tripbot import Tripbot
from adanalife_k8s.constructs.vlc import VlcServer, emit_dashcam_volume
from adanalife_k8s.supporting import emit_supporting


class AppsChart(Chart):
    """STATELESS app workloads for one environment: the namespace-scoped
    supporting resources (ESO store, shared-secrets, cert-manager issuers) plus
    the app constructs. Mirrors the legacy `k8s/overlays/<env>` umbrella set,
    minus the stateful pieces.

    The stateful resources (postgres + the dashcam PV/PVC) live in **DataChart**,
    a separate deploy unit / Argo Application, so routine app churn can't disturb
    the database or volumes (see DataChart).

    Deliberately excluded (applied via their own tasks, never on every apply):
    the tripbot one-shot Jobs (auth-bootstrap + seed) and the dashcam-cv vector
    fill — see JobsChart / DashcamCVChart below.
    """

    def __init__(self, scope: Construct, id: str, *, env: EnvConfig):
        super().__init__(scope, id, namespace=env.namespace or None)
        self.env = env

        # --- supporting: SecretStore + shared-secrets + cert-manager issuers ---
        emit_supporting(self, env)

        # --- tripbot (bot Deployment + Service + Ingress + ExternalSecrets) ---
        Tripbot(self, env=env)

        # --- vlc-server (shared; per-platform-ready) ---
        VlcServer(self, env=env)

        # --- onscreens-server (NATS consumer; its own Deployment) ---
        OnscreensServer(self, env=env)

        # --- OBS, one instance per streaming platform present in this env ---
        for platform in env.platforms:
            # twitch streams by default in prod (ESO stream-key); everything else
            # boots idle until toggled on. youtube carries STREAM_PLATFORM=youtube.
            streaming = platform == "twitch" and env.name == "prod-1"
            ObsInstance(
                self, platform, env=env,
                streaming=streaming,
                stream_key_sm=f"k8s/obs/{platform}-stream-key" if streaming else None,
                extra_config={"STREAM_PLATFORM": "youtube"} if platform == "youtube" else None,
            )


class DataChart(Chart):
    """STATEFUL resources for one environment, isolated from AppsChart so the
    high-churn stateless apps can't affect them: the postgres StatefulSet (+ its
    PVC/StorageClass, backup CronJob) and the dashcam NFS PV/PVC.

    Applied as its own deploy unit / Argo Application with **prune disabled** —
    so even if one of these vanished from the manifests, the controller would
    never delete the database or volumes. Reclaim policy is Retain on the
    precious PVs (prod postgres → local-path-retain; dashcam → Retain), so the
    bytes survive object deletion regardless. Sync this BEFORE the apps unit
    (it's a dependency: tripbot/vlc need postgres + the dashcam PVC).
    """

    def __init__(self, scope: Construct, id: str, *, env: EnvConfig):
        super().__init__(scope, id, namespace=env.namespace or None)
        self.env = env

        # --- postgres (StatefulSet; prod adds StorageClass + backup CronJob) ---
        Postgres(self, env=env)

        # --- dashcam NFS PV/PVC (nfs envs only; no-op on hostPath local/dev) ---
        emit_dashcam_volume(self, env)


class DashcamCVChart(Chart):
    """The dashcam-cv vector-fill workload (CronJob/Job/PVC/PriorityClass).

    A separate deploy unit because it was never in the env umbrellas — it's a
    background batch job staged via its own task, currently stage-only.
    """

    def __init__(self, scope: Construct, id: str, *, env: EnvConfig):
        super().__init__(scope, id, namespace=env.namespace or None)
        DashcamCV(self, env=env)


class JobsChart(Chart):
    """tripbot one-shot Jobs (auth-bootstrap bot+broadcaster, seed). Applied
    per-env via `task tripbot:<env>:auth:bootstrap` / `:seed`, never on a normal
    apply (running a seed/auth job on every reconcile would be wrong)."""

    def __init__(self, scope: Construct, id: str, *, env: EnvConfig):
        super().__init__(scope, id, namespace=env.namespace or None)
        from adanalife_k8s.constructs.tripbot import emit_jobs
        emit_jobs(self, env)
