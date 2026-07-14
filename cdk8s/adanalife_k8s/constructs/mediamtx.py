"""MediaMTX — the RTSP relay between the playout publisher and OBS.

The playout server (the adanalife/playout repo) publishes the dashcam stream
into MediaMTX over RTSP; OBS pulls from MediaMTX. The relay decouples the
OBS-facing RTSP endpoint from the publisher's lifecycle — a playout restart
doesn't invalidate the endpoint OBS is reading — and adds TCP transport for
off-cluster viewers. One instance per platform, deliberately: it keeps the
per-stream blast-radius isolation the fleet already uses (vlc-{platform},
obs-{platform}), so a relay restart only ever touches one platform's stream.

Emits, per platform in env.platforms, into the env's app namespace:
  * ConfigMap mediamtx-{platform}-config — mediamtx.yml (RTSP + metrics only;
    every other protocol disabled) with a single explicit `dashcam` path.
  * Deployment mediamtx-{platform} — one replica, Recreate (a relay handles one
    live stream; never run two side by side during a rollout).
  * Service mediamtx-{platform} — rtsp/TCP + rtp/rtcp UDP + metrics.

Publishers/readers address it as rtsp://mediamtx-{platform}:8554/dashcam
(cross-namespace: rtsp://mediamtx-{platform}.{ns}.svc.cluster.local:8554/dashcam).
"""

from __future__ import annotations

import imports.k8s as k8s
from constructs import Construct

from adanalife_k8s.config import EnvConfig
from adanalife_k8s.naming import meta_labels, selector

# GHCR mirror, not Docker Hub (the ghcr-base-image-mirrors decision) — the
# mirror pair is registered in the playout repo's mirror-images workflow.
IMAGE = "ghcr.io/adanalife/mirror/mediamtx:v1.19.2"
RTSP_PORT = 8554
RTP_PORT = 8000
RTCP_PORT = 8001
METRICS_PORT = 9998

# RTSP on both TCP and UDP transports (the MediaMTX default) + Prometheus
# metrics; every other protocol off. The single explicit `dashcam` path keeps
# the namespace closed — a typo'd publish target errors instead of silently
# creating a path nothing reads. Default path config: any publisher, any reader
# (in-cluster only; the Service is ClusterIP).
_CONFIG = f"""\
rtsp: yes
rtspAddress: :{RTSP_PORT}
rtpAddress: :{RTP_PORT}
rtcpAddress: :{RTCP_PORT}
rtmp: no
hls: no
webrtc: no
srt: no
metrics: yes
metricsAddress: :{METRICS_PORT}
paths:
  dashcam:
"""


class Mediamtx(Construct):
    """One RTSP relay per platform in the env's app namespace — the endpoint
    OBS pulls the dashcam stream from, fed by the playout publisher."""

    def __init__(self, scope: Construct, id: str = "mediamtx", *, env: EnvConfig):
        super().__init__(scope, id)
        for platform in env.platforms:
            self._instance(env, platform)

    def _instance(self, env: EnvConfig, platform: str):
        name = f"mediamtx-{platform}"
        ns = env.namespace or None
        labels = meta_labels(name)
        sel = selector(name)

        k8s.KubeConfigMap(
            self,
            f"{platform}-config",
            metadata=k8s.ObjectMeta(name=f"{name}-config", namespace=ns, labels=labels),
            data={"mediamtx.yml": _CONFIG},
        )

        container = k8s.Container(
            name=name,
            image=IMAGE,
            security_context=k8s.SecurityContext(
                allow_privilege_escalation=False,
                capabilities=k8s.Capabilities(drop=["ALL"]),
            ),
            ports=[
                k8s.ContainerPort(name="rtsp", container_port=RTSP_PORT),
                k8s.ContainerPort(name="rtp", container_port=RTP_PORT, protocol="UDP"),
                k8s.ContainerPort(
                    name="rtcp", container_port=RTCP_PORT, protocol="UDP"
                ),
                k8s.ContainerPort(name="metrics", container_port=METRICS_PORT),
            ],
            readiness_probe=k8s.Probe(
                tcp_socket=k8s.TcpSocketAction(
                    port=k8s.IntOrString.from_string("rtsp")
                ),
                initial_delay_seconds=5,
                period_seconds=5,
            ),
            resources=k8s.ResourceRequirements(
                requests={
                    "cpu": k8s.Quantity.from_string("50m"),
                    "memory": k8s.Quantity.from_string("64Mi"),
                },
                limits={"memory": k8s.Quantity.from_string("256Mi")},
            ),
            volume_mounts=[
                # MediaMTX reads /mediamtx.yml by default; mount just the file.
                k8s.VolumeMount(
                    name="config",
                    mount_path="/mediamtx.yml",
                    sub_path="mediamtx.yml",
                    read_only=True,
                )
            ],
        )

        k8s.KubeDeployment(
            self,
            f"{platform}-deployment",
            metadata=k8s.ObjectMeta(name=name, namespace=ns, labels=labels),
            spec=k8s.DeploymentSpec(
                replicas=1,
                # One relay per stream — never run two side by side in a rollout.
                strategy=k8s.DeploymentStrategy(type="Recreate"),
                selector=k8s.LabelSelector(match_labels=sel),
                template=k8s.PodTemplateSpec(
                    metadata=k8s.ObjectMeta(labels=sel),
                    spec=k8s.PodSpec(
                        security_context=k8s.PodSecurityContext(
                            seccomp_profile=k8s.SeccompProfile(type="RuntimeDefault"),
                        ),
                        containers=[container],
                        volumes=[
                            k8s.Volume(
                                name="config",
                                config_map=k8s.ConfigMapVolumeSource(
                                    name=f"{name}-config"
                                ),
                            )
                        ],
                    ),
                ),
            ),
        )

        k8s.KubeService(
            self,
            f"{platform}-service",
            metadata=k8s.ObjectMeta(name=name, namespace=ns, labels=labels),
            spec=k8s.ServiceSpec(
                selector=sel,
                ports=[
                    k8s.ServicePort(
                        name="rtsp",
                        port=RTSP_PORT,
                        target_port=k8s.IntOrString.from_string("rtsp"),
                    ),
                    k8s.ServicePort(
                        name="rtp",
                        port=RTP_PORT,
                        protocol="UDP",
                        target_port=k8s.IntOrString.from_string("rtp"),
                    ),
                    k8s.ServicePort(
                        name="rtcp",
                        port=RTCP_PORT,
                        protocol="UDP",
                        target_port=k8s.IntOrString.from_string("rtcp"),
                    ),
                    k8s.ServicePort(
                        name="metrics",
                        port=METRICS_PORT,
                        target_port=k8s.IntOrString.from_string("metrics"),
                    ),
                ],
            ),
        )
