"""Per-environment configuration — the matrix knobs the Kustomize overlays vary.

One `EnvConfig` replaces the per-app `overlays/<env>` sprawl. Charts/constructs
read these fields instead of branching on env name inline. App-specific config
that *also* varies by env (the big vlc/tripbot literal blocks) is assembled in
each construct from these knobs; this table holds only the cross-app values.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field


@dataclass(frozen=True)
class EnvConfig:
    name: str  # prod-1 | stage-1 | development | local
    namespace: str
    cluster: str  # minipc | k3d | local
    aws_account: str  # adanalife-prod | adanalife-stage | "" (local)
    image_tag: str  # floating tag (latest | develop) for components without a pin
    dns_base: str  # prod.whereisdana.today | stage... | dev...  ("" for local)
    nats_url: str
    sentry_env: str  # SENTRY_ENVIRONMENT (prod-1 | stage-1 | development)
    binary_env: str = "development"  # ENV= the Go config validator accepts: production|staging|development
    deployment_env: str = (
        "development"  # OTEL deployment.environment + telemetry env id
    )
    secret_source: str = "eso"  # eso | local
    gpu: bool = False  # request gpu.intel.com/i915
    # vlc-server's iGPU claim is gated on (gpu and vlc_gpu). Default True keeps the
    # claim wherever the env has a GPU; set False to drop just vlc's claim while OBS
    # keeps the iGPU. vlc proved it doesn't need the GPU (stream-copy + trivial
    # software decode); OBS does (VAAPI encode). See VlcServer in constructs/vlc.py.
    vlc_gpu: bool = True
    obs_encoder: str = "obs_x264"  # ffmpeg_vaapi_tex on GPU envs
    obs_quality: str = "low"  # low | high
    dashcam_mode: str = "hostpath"  # nfs | hostpath
    tailscale: bool = False  # emit the tailscale Ingress
    otel: bool = False  # OTEL_SDK_DISABLED=false when True
    postgres_size: str = "5Gi"
    postgres_storage_class: str = ""  # "" = cluster default; local-path-retain on prod
    postgres_backup: bool = False
    # "" → postgres co-locates in the app namespace (default, byte-identical
    # render). Set to an isolated namespace (e.g. "stage-1-data") to move the DB
    # StatefulSet + its ESO SecretStore out of the app namespace, so deleting the
    # app namespace can't drop the database. Apps reach it cross-namespace via the
    # postgres_host FQDN. The dashcam PVC does NOT move (vlc mounts it; PVCs are
    # namespace-local) — it shifts to SupportingChart in the app namespace.
    data_namespace: str = ""
    external_dns_role_arn: str = (
        ""  # cert-manager DNS-01 Route53 role (per AWS account)
    )
    lan_ip: str = (
        "192.168.1.200"  # mini-PC node IP external-dns/traefik target (platform Helm)
    )
    nfs_server: str = ""  # dashcam NFS export (nfs mode); from $NFS_SERVER at synth
    nfs_path: str = ""  # dashcam NFS path; from the $nfs_path_env var at synth
    # Which env var supplies this env's dashcam path. Both nfs envs now read the
    # shared $NFS_PATH, which points at the canonical regenerated _opt/clips
    # corpus (smaller, +faststart, fixes the corrupt airing clips). The override
    # mechanism stays generic — it let stage stream _opt while prod stayed on the
    # airing _all export during the regen — but no env diverges today. Falls back
    # to $NFS_PATH when an override is unset, so the golden render is unchanged.
    nfs_path_env: str = "NFS_PATH"
    nfs_pv_name: str = (
        "vlc-dashcam-nfs"  # PVs bind 1:1 — stage needs its own (vlc-dashcam-nfs-stage)
    )
    # Streaming platforms present in this env (obs instances). twitch everywhere;
    # youtube currently stage-only while the bot side is built out.
    platforms: tuple[str, ...] = ("twitch",)
    # --- prod-stream protection (2026-06-11 stage-starves-prod incident) ---
    # PriorityClassName stamped on the env's app Deployment pods; when set,
    # SupportingChart also emits the PriorityClass itself. Prod outranks every
    # default-priority (0) pod, so under node pressure the scheduler preempts
    # co-tenant stage workloads, never the live stream.
    priority_class: str = ""
    # CPU requests for the stream-critical pair. Requests are the CFS weight —
    # under CPU contention each cgroup gets CPU proportional to its request, so
    # prod's real-sized requests guarantee the encode/decode chain its share no
    # matter how many 200m co-tenant pods burst. Non-prod stays at the small
    # default so stage/dev keep their light footprint.
    obs_cpu_request: str = "200m"
    vlc_cpu_request: str = "200m"
    # ResourceQuota hard caps for the app namespace (emitted by SupportingChart
    # when non-empty). Caps what the env can REQUEST in aggregate — scaling up
    # too many deployments hits the quota and pods stay unscheduled instead of
    # crowding the node. NB: quota on requests.* means every pod in the
    # namespace must declare requests for those resources or be rejected.
    app_quota: dict[str, str] = field(default_factory=dict)
    # Non-standard public HTTPS port carried in externally-visible URLs
    # (EXTERNAL_URL, registered OAuth redirect URIs). Only dev needs it — k3d's
    # traefik is mapped to host :9443 because Colima can't bind :443.
    external_port: str = ""

    @property
    def otel_disabled(self) -> str:
        """OTEL_SDK_DISABLED literal — disabled everywhere OTEL isn't on."""
        return "false" if self.otel else "true"

    @property
    def tls(self) -> bool:
        """Whether app ingresses get cert-manager TLS (minipc envs only)."""
        return self.cluster == "minipc"

    @property
    def data_ns(self) -> str:
        """Namespace the stateful data unit (postgres + its SecretStore) lands in:
        the app namespace by default, or the isolated one when data_namespace set."""
        return self.data_namespace or self.namespace

    @property
    def data_isolated(self) -> bool:
        """True when postgres lives in its own namespace, split from the app ns."""
        return bool(self.data_namespace) and self.data_namespace != self.namespace

    @property
    def postgres_host(self) -> str:
        """DATABASE_HOST apps connect to: the bare Service name when co-located
        (parity), the cross-namespace FQDN when the DB is isolated."""
        return (
            f"postgres.{self.data_namespace}.svc.cluster.local"
            if self.data_isolated
            else "postgres"
        )


# Stage and dev share the adanalife-stage account → same ExternalDNSRole ARN.
_STAGE_ROLE = "arn:aws:iam::413585268653:role/ExternalDNSRole"
_PROD_ROLE = "arn:aws:iam::704461573429:role/ExternalDNSRole"


# Per-env table. Mirrors the Kustomize overlays; the source of truth once those
# overlays are retired. Values cross-checked against k8s/apps/*/overlays/<env>.
ENVS: dict[str, EnvConfig] = {
    "prod-1": EnvConfig(
        name="prod-1",
        namespace="prod-1",
        cluster="minipc",
        aws_account="adanalife-prod",
        image_tag="latest",
        dns_base="prod.whereisdana.today",
        nats_url="nats://nats.prod-1-platform.svc.cluster.local:4222",
        sentry_env="prod-1",
        binary_env="production",
        deployment_env="prod-1",
        gpu=True,
        obs_encoder="ffmpeg_vaapi_tex",
        obs_quality="high",
        dashcam_mode="nfs",
        tailscale=True,
        otel=True,
        postgres_size="50Gi",
        postgres_storage_class="local-path-retain",
        postgres_backup=True,
        external_dns_role_arn=_PROD_ROLE,
        # Streams the shared $NFS_PATH — now the canonical regenerated _opt/clips
        # corpus, cut over from the airing _all export once the regen completed.
        nfs_pv_name="vlc-dashcam-nfs",
        # The DB lives in its own namespace so a `kubectl delete ns prod-1` can't
        # take years of irreplaceable data.
        data_namespace="prod-1-data",
        # youtube is staged here so Argo creates the prod-youtube Applications,
        # but the tripbot repo renders that stack at replicas=0 (parked_platforms)
        # until stage-youtube is shut down and prod-youtube is turned on — the
        # minipc never runs two youtube stacks at once. This list is the Argo
        # fan-out contract; it must match the platforms tripbot's cdk8s emits.
        platforms=("twitch", "youtube"),
        # The live stream always wins: prod app pods outrank default-priority
        # co-tenants (stage, dashcam-cv), and the encode/decode pair carries
        # real CPU requests so contention can't starve it (20-core node; the
        # whole prod chain requests ~3.2 CPU).
        priority_class="prod-stream",
        obs_cpu_request="2",
        vlc_cpu_request="1",
    ),
    "stage-1": EnvConfig(
        name="stage-1",
        namespace="stage-1",
        cluster="minipc",
        aws_account="adanalife-stage",
        image_tag="develop",
        dns_base="stage.whereisdana.today",
        nats_url="nats://nats.stage-1-platform.svc.cluster.local:4222",
        sentry_env="stage-1",
        binary_env="staging",
        deployment_env="stage-1",
        gpu=True,
        # vlc's iGPU claim was proven unnecessary on 2026-06-12 (stream-copy +
        # trivial software decode — CPU flat at ~0.04 cores with and without
        # /dev/dri). Dropping it frees an iGPU slot and eases the co-tenant
        # contention from the 2026-06-11 stutter incident. OBS keeps the iGPU
        # (it needs VAAPI encode). Stage first; prod-1 follows after a careful
        # rollout on the live twitch stream.
        vlc_gpu=False,
        obs_encoder="ffmpeg_vaapi_tex",
        obs_quality="low",
        dashcam_mode="nfs",
        tailscale=True,
        otel=False,
        postgres_size="10Gi",
        postgres_storage_class="local-path",
        external_dns_role_arn=_STAGE_ROLE,
        nfs_pv_name="vlc-dashcam-nfs-stage",
        # Stage reads the shared $NFS_PATH (= the canonical _opt/clips corpus),
        # same as prod — the corpus regen is complete, so the temporary
        # STAGE_NFS_PATH override that let stage run ahead on the in-progress
        # corpus has collapsed. Stage keeps its own PV name (PVs bind 1:1).
        # Stage rehearses DB-in-its-own-namespace: postgres + its SecretStore land
        # in stage-1-data, so a `kubectl delete ns stage-1` can't take the DB. prod
        # follows on its next wipe (set prod-1's data_namespace to prod-1-data).
        data_namespace="stage-1-data",
        # The YouTube platform stack burns in on stage first (tripbot-youtube
        # binds chat once a broadcast is live; vlc-youtube self-sustains;
        # obs-youtube boots idle — the streaming toggle is prod-twitch-only).
        # prod follows once the stage burn-in + dual-iGPU-encode validation
        # pass.
        #
        # twitch is back ON (2026-06-19) to test the platform-gateway end to
        # end: stage tripbot-twitch routes its Helix calls through gateway-twitch.
        # The 2026-06-11 prod-stutter that forced twitch OFF here was the stage
        # twitch *VLC decode + OBS render* contending for the shared iGPU — so
        # only tripbot-twitch (no GPU) is meant to run; vlc/obs/onscreens-twitch
        # stay scaled to 0 (stage selfHeal is off + replicas are unmanaged, so a
        # hand/console scale sticks). Budget is still two live streams total:
        # prod-twitch + stage-youtube.
        platforms=("youtube", "twitch"),
        # Guardrail from the same incident: cap what stage can request in
        # aggregate, so "accidentally scaled up too many stage deployments"
        # parks pods Unschedulable instead of crowding prod off the node.
        # CPU/memory sized roomy — youtube stack (~0.5 CPU / 1.3Gi requests) +
        # dashcam-cv embed jobs (2× 1 CPU / 5Gi) + one-shot jobs fit with
        # headroom; the node has 20 CPU / 31Gi. iGPU claims sized TIGHT to
        # what stage runs today: vlc + obs steady (2) + 1 surge slot for
        # vlc's RollingUpdate maxSurge=1 (obs is Recreate, no surge). Claims,
        # not GPU time — encode contention is governed by the two-stream
        # budget above, not by quota. Bump alongside re-adding twitch.
        app_quota={
            "requests.cpu": "6",
            "requests.memory": "16Gi",
            "requests.gpu.intel.com/i915": "3",
            "pods": "30",
        },
    ),
    "development": EnvConfig(
        name="development",
        namespace="development",
        cluster="k3d",
        aws_account="adanalife-stage",
        image_tag="develop",
        dns_base="dev.whereisdana.today",
        nats_url="nats://nats.development-platform.svc.cluster.local:4222",
        sentry_env="development",
        binary_env="staging",
        deployment_env="development",
        gpu=False,
        obs_quality="low",
        dashcam_mode="hostpath",
        tailscale=False,
        otel=False,
        external_dns_role_arn=_STAGE_ROLE,
        platforms=("twitch",),
        external_port="9443",
    ),
    "local": EnvConfig(
        name="local",
        namespace="default",
        cluster="local",
        aws_account="",
        image_tag="latest",
        dns_base="",
        nats_url="",
        sentry_env="development",
        binary_env="staging",
        deployment_env="development",
        secret_source="local",
        gpu=False,
        obs_quality="low",
        dashcam_mode="hostpath",
        tailscale=False,
        otel=False,
        platforms=("twitch",),
    ),
}


def load_env(name: str) -> EnvConfig:
    try:
        env = ENVS[name]
    except KeyError:
        raise SystemExit(f"unknown env {name!r}; known: {', '.join(ENVS)}")
    from dataclasses import replace

    # NFS coordinates are deployment-host-specific (gitignored in Kustomize as
    # dashcam-nfs.local.yaml); thread them in from the environment at synth so
    # they never get committed. Placeholders match the legacy .example render.
    if env.dashcam_mode == "nfs":
        # Each env reads its own path var, falling back to the shared $NFS_PATH
        # (now the canonical regenerated _opt/clips corpus) — so an unset override
        # renders identically to before (and the committed golden keeps the
        # placeholder). No env overrides today; the mechanism stays for the next
        # time one env needs to run ahead of another on a fresh corpus.
        nfs_path = os.environ.get(env.nfs_path_env) or os.environ.get(
            "NFS_PATH", "<export path>"
        )
        env = replace(
            env,
            nfs_server=os.environ.get("NFS_SERVER", "<NFS server address>"),
            nfs_path=nfs_path,
        )
    return env
