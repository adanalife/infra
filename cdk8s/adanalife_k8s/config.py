"""Per-environment configuration — the matrix knobs the Kustomize overlays vary.

One `EnvConfig` replaces the per-app `overlays/<env>` sprawl. Charts/constructs
read these fields instead of branching on env name inline.
"""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class EnvConfig:
    name: str               # prod-1 | stage-1 | development | local
    namespace: str
    cluster: str            # minipc | bees | local
    aws_account: str        # adanalife-prod | adanalife-stage | "" (local)
    image_tag: str          # latest | develop
    dns_base: str           # prod.whereisdana.today | stage... | dev...  ("" for local)
    nats_url: str
    sentry_env: str
    secret_source: str = "eso"          # eso | local
    gpu: bool = False                   # request gpu.intel.com/i915
    obs_encoder: str = "obs_x264"       # ffmpeg_vaapi_tex on GPU envs
    obs_quality: str = "low"            # low | high
    dashcam_mode: str = "hostpath"      # nfs | hostpath
    tailscale: bool = False             # emit the tailscale Ingress
    otel: bool = False
    postgres_size: str = "5Gi"
    postgres_storage_class: str = ""    # "" = cluster default; local-path-retain on prod
    postgres_backup: bool = False
    # Streaming platforms present in this env (obs instances). twitch everywhere;
    # youtube currently stage-only while the bot side is built out.
    platforms: tuple[str, ...] = ("twitch",)


# Per-env table. Mirrors the Kustomize overlays; the source of truth once those
# overlays are retired. Values cross-checked against k8s/apps/*/overlays/<env>.
ENVS: dict[str, EnvConfig] = {
    "prod-1": EnvConfig(
        name="prod-1", namespace="prod-1", cluster="minipc",
        aws_account="adanalife-prod", image_tag="latest",
        dns_base="prod.whereisdana.today",
        nats_url="nats://nats.prod-1-platform.svc.cluster.local:4222",
        sentry_env="prod-1", gpu=True, obs_encoder="ffmpeg_vaapi_tex",
        obs_quality="high", dashcam_mode="nfs", tailscale=True, otel=True,
        postgres_size="50Gi", postgres_storage_class="local-path-retain",
        postgres_backup=True, platforms=("twitch",),
    ),
    "stage-1": EnvConfig(
        name="stage-1", namespace="stage-1", cluster="minipc",
        aws_account="adanalife-stage", image_tag="develop",
        dns_base="stage.whereisdana.today",
        nats_url="nats://nats.stage-1-platform.svc.cluster.local:4222",
        sentry_env="stage-1", gpu=True, obs_encoder="ffmpeg_vaapi_tex",
        obs_quality="low", dashcam_mode="nfs", tailscale=True, otel=False,
        platforms=("twitch", "youtube"),
    ),
    "development": EnvConfig(
        name="development", namespace="development", cluster="bees",
        aws_account="adanalife-stage", image_tag="develop",
        dns_base="dev.whereisdana.today",
        nats_url="nats://nats.development-platform.svc.cluster.local:4222",
        sentry_env="development", gpu=False, obs_quality="low",
        dashcam_mode="hostpath", tailscale=False, otel=False,
        platforms=("twitch",),
    ),
    "local": EnvConfig(
        name="local", namespace="default", cluster="local",
        aws_account="", image_tag="latest", dns_base="",
        nats_url="", sentry_env="development", secret_source="local",
        gpu=False, obs_quality="low", dashcam_mode="hostpath",
        tailscale=False, otel=False, platforms=("twitch",),
    ),
}


def load_env(name: str) -> EnvConfig:
    try:
        return ENVS[name]
    except KeyError:
        raise SystemExit(f"unknown env {name!r}; known: {', '.join(ENVS)}")
