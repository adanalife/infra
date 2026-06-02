"""Per-environment configuration — the matrix knobs the Kustomize overlays vary.

One `EnvConfig` replaces the per-app `overlays/<env>` sprawl. Charts/constructs
read these fields instead of branching on env name inline. App-specific config
that *also* varies by env (the big vlc/tripbot literal blocks) is assembled in
each construct from these knobs; this table holds only the cross-app values.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class EnvConfig:
    name: str  # prod-1 | stage-1 | development | local
    namespace: str
    cluster: str  # minipc | bees | local
    aws_account: str  # adanalife-prod | adanalife-stage | "" (local)
    image_tag: str  # latest | develop
    dns_base: str  # prod.whereisdana.today | stage... | dev...  ("" for local)
    nats_url: str
    sentry_env: str  # SENTRY_ENVIRONMENT (prod-1 | stage-1 | development)
    binary_env: str = "development"  # ENV= the Go config validator accepts: production|staging|development
    deployment_env: str = (
        "development"  # OTEL deployment.environment + telemetry env id
    )
    secret_source: str = "eso"  # eso | local
    gpu: bool = False  # request gpu.intel.com/i915
    obs_encoder: str = "obs_x264"  # ffmpeg_vaapi_tex on GPU envs
    obs_quality: str = "low"  # low | high
    dashcam_mode: str = "hostpath"  # nfs | hostpath
    tailscale: bool = False  # emit the tailscale Ingress
    otel: bool = False  # OTEL_SDK_DISABLED=false when True
    postgres_size: str = "5Gi"
    postgres_storage_class: str = ""  # "" = cluster default; local-path-retain on prod
    postgres_backup: bool = False
    external_dns_role_arn: str = (
        ""  # cert-manager DNS-01 Route53 role (per AWS account)
    )
    lan_ip: str = (
        "192.168.1.200"  # mini-PC node IP external-dns/traefik target (platform Helm)
    )
    nfs_server: str = ""  # dashcam NFS export (nfs mode); from $NFS_SERVER at synth
    nfs_path: str = ""  # dashcam NFS path; from $NFS_PATH at synth
    nfs_pv_name: str = (
        "vlc-dashcam-nfs"  # PVs bind 1:1 — stage needs its own (vlc-dashcam-nfs-stage)
    )
    vlc_inpod_onscreens: bool = (
        False  # prod-only: re-expose the in-pod onscreens on :8081 until OBS cutover
    )
    # Streaming platforms present in this env (obs instances). twitch everywhere;
    # youtube currently stage-only while the bot side is built out.
    platforms: tuple[str, ...] = ("twitch",)

    @property
    def otel_disabled(self) -> str:
        """OTEL_SDK_DISABLED literal — disabled everywhere OTEL isn't on."""
        return "false" if self.otel else "true"

    @property
    def tls(self) -> bool:
        """Whether app ingresses get cert-manager TLS (minipc envs only)."""
        return self.cluster == "minipc"


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
        nfs_pv_name="vlc-dashcam-nfs",
        vlc_inpod_onscreens=True,
        platforms=("twitch",),
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
        obs_encoder="ffmpeg_vaapi_tex",
        obs_quality="low",
        dashcam_mode="nfs",
        tailscale=True,
        otel=False,
        postgres_size="10Gi",
        postgres_storage_class="local-path",
        external_dns_role_arn=_STAGE_ROLE,
        nfs_pv_name="vlc-dashcam-nfs-stage",
        platforms=("twitch", "youtube"),
    ),
    "development": EnvConfig(
        name="development",
        namespace="development",
        cluster="bees",
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
    # NFS coordinates are deployment-host-specific (gitignored in Kustomize as
    # dashcam-nfs.local.yaml); thread them in from the environment at synth so
    # they never get committed. Placeholders match the legacy .example render.
    if env.dashcam_mode == "nfs":
        from dataclasses import replace

        env = replace(
            env,
            nfs_server=os.environ.get("NFS_SERVER", "<NFS server address>"),
            nfs_path=os.environ.get("NFS_PATH", "<export path>"),
        )
    return env
