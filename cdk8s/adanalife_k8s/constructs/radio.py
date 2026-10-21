"""The fleet's own internet-radio station — an Icecast server fed by Liquidsoap,
shuffling one directory of the music library, so tripbot's radio bed has a
station of ours to play alongside the third-party ones in its station list.

One pod, two containers: Liquidsoap encodes the playlist to MP3 and pushes it to
Icecast over the pod's loopback; Icecast serves it with in-band ICY metadata
(StreamTitle = "artist - title"), which is what the bed's now-playing reads.

Plays off `obs-music-local`, the node-local mirror the album bed reads, never the
NFS share (decisions/prod-stream-path-no-nas-dependency): a station is staged by
putting a directory on the share and running `task k8s:<env>:music-localize`.
A station whose directory is still empty plays silence rather than crashing.

The source/admin password is minted per pod by an initContainer onto a
memory-backed emptyDir both containers read, so there is no credential to store
anywhere and the Service's port is useless to anyone else as a source.

Listeners address it as
http://radio.<ns>.svc.cluster.local:8000/<mount> — the URL that goes in
tripbot's station list (SSM /k8s/tripbot/radio-stations). ClusterIP only.
"""

from __future__ import annotations

import imports.k8s as k8s
from constructs import Construct

from adanalife_k8s.config import EnvConfig
from adanalife_k8s.constructs.dashcam import MINIPC_NODE
from adanalife_k8s.constructs.music import LOCAL_CLAIM
from adanalife_k8s.naming import (
    CONFIG_HASH_ANNOTATION,
    config_hash,
    meta_labels,
    selector,
)

# Upstream registries rather than ghcr mirrors: the mirror rule
# (ghcr-base-image-mirrors) exists for CI pulls, and these are cluster pulls.
# shortcut: liquidsoap comes off Docker Hub; mirror it via a mirror-images.yml
# pair if a pull ever hits the Hub rate limit.
ICECAST_IMAGE = "ghcr.io/libretime/icecast:2.5.0-alpine"
LIQUIDSOAP_IMAGE = "docker.io/savonet/liquidsoap:v2.4.6"

NAME = "radio"
PORT = 8000
_MUSIC_DIR = "/music"
_RUN_DIR = "/run/radio"
_PASSWORD_FILE = f"{_RUN_DIR}/password"

# One mount per station: (mount, directory on the music share, display name).
STATIONS = (("halloween", "halloween", "Halloween"),)

# The images' own users (icecast owns /etc/icecast.xml, which its entrypoint
# edits in place); runAsNonRoot needs them numeric.
_ICECAST_UID = 1000
_LIQUIDSOAP_UID = 100


def _script() -> str:
    outputs = "\n".join(
        f"""output.icecast(
  %mp3(bitrate = 128),
  host = "127.0.0.1",
  port = {PORT},
  password = password,
  mount = "{mount}",
  name = "{title}",
  mksafe(playlist(mode = "randomize", reload_mode = "watch", "{_MUSIC_DIR}/{folder}"))
)"""
        for mount, folder, title in STATIONS
    )
    return f"""settings.log.stdout := true
settings.log.file := false
password = string.trim(file.contents("{_PASSWORD_FILE}"))
{outputs}
"""


class Radio(Construct):
    def __init__(self, scope: Construct, id: str = "radio", *, env: EnvConfig):
        super().__init__(scope, id)
        ns = env.namespace or None
        labels = meta_labels(NAME)
        sel = selector(NAME)
        config = {"radio.liq": _script()}
        q = k8s.Quantity.from_string

        k8s.KubeConfigMap(
            self,
            "config",
            metadata=k8s.ObjectMeta(name=f"{NAME}-config", namespace=ns, labels=labels),
            data=config,
        )

        run = k8s.VolumeMount(name="run", mount_path=_RUN_DIR)
        locked_down = k8s.SecurityContext(
            allow_privilege_escalation=False,
            capabilities=k8s.Capabilities(drop=["ALL"]),
        )

        k8s.KubeDeployment(
            self,
            "deployment",
            metadata=k8s.ObjectMeta(name=NAME, namespace=ns, labels=labels),
            spec=k8s.DeploymentSpec(
                replicas=1,
                strategy=k8s.DeploymentStrategy(type="Recreate"),
                selector=k8s.LabelSelector(match_labels=sel),
                template=k8s.PodTemplateSpec(
                    metadata=k8s.ObjectMeta(
                        labels=sel,
                        annotations={CONFIG_HASH_ANNOTATION: config_hash(config)},
                    ),
                    spec=k8s.PodSpec(
                        # The music claim is local-path, so it only exists here.
                        node_selector={"kubernetes.io/hostname": MINIPC_NODE},
                        security_context=k8s.PodSecurityContext(
                            run_as_non_root=True,
                            seccomp_profile=k8s.SeccompProfile(type="RuntimeDefault"),
                        ),
                        init_containers=[
                            k8s.Container(
                                name="password",
                                image=ICECAST_IMAGE,
                                command=[
                                    "sh",
                                    "-c",
                                    "head -c 24 /dev/urandom | base64 | tr -d '/+=' "
                                    f"> {_PASSWORD_FILE} && chmod 444 {_PASSWORD_FILE}",
                                ],
                                security_context=locked_down,
                                resources=k8s.ResourceRequirements(
                                    requests={"cpu": q("10m"), "memory": q("16Mi")},
                                    limits={"memory": q("32Mi")},
                                ),
                                volume_mounts=[run],
                            )
                        ],
                        containers=[
                            k8s.Container(
                                name="icecast",
                                image=ICECAST_IMAGE,
                                # The image's entrypoint writes these env vars
                                # into icecast.xml before exec'ing icecast.
                                command=[
                                    "sh",
                                    "-c",
                                    f'p="$(cat {_PASSWORD_FILE})"; '
                                    'export ICECAST_SOURCE_PASSWORD="$p" '
                                    'ICECAST_ADMIN_PASSWORD="$p" '
                                    'ICECAST_RELAY_PASSWORD="$p"; '
                                    "exec docker-entrypoint icecast -c /etc/icecast.xml",
                                ],
                                ports=[
                                    k8s.ContainerPort(name="http", container_port=PORT)
                                ],
                                readiness_probe=k8s.Probe(
                                    tcp_socket=k8s.TcpSocketAction(
                                        port=k8s.IntOrString.from_string("http")
                                    ),
                                    period_seconds=10,
                                ),
                                security_context=locked_down,
                                resources=k8s.ResourceRequirements(
                                    requests={"cpu": q("20m"), "memory": q("32Mi")},
                                    limits={"memory": q("128Mi")},
                                ),
                                volume_mounts=[run],
                            ),
                            k8s.Container(
                                name="liquidsoap",
                                image=LIQUIDSOAP_IMAGE,
                                args=["/etc/radio/radio.liq"],
                                security_context=k8s.SecurityContext(
                                    allow_privilege_escalation=False,
                                    capabilities=k8s.Capabilities(drop=["ALL"]),
                                    run_as_user=_LIQUIDSOAP_UID,
                                ),
                                # One 128k MP3 encode per station.
                                resources=k8s.ResourceRequirements(
                                    requests={"cpu": q("100m"), "memory": q("128Mi")},
                                    limits={"memory": q("512Mi")},
                                ),
                                volume_mounts=[
                                    run,
                                    k8s.VolumeMount(
                                        name="config",
                                        mount_path="/etc/radio",
                                        read_only=True,
                                    ),
                                    k8s.VolumeMount(
                                        name="music",
                                        mount_path=_MUSIC_DIR,
                                        read_only=True,
                                    ),
                                ],
                            ),
                        ],
                        volumes=[
                            k8s.Volume(
                                name="run",
                                empty_dir=k8s.EmptyDirVolumeSource(medium="Memory"),
                            ),
                            k8s.Volume(
                                name="config",
                                config_map=k8s.ConfigMapVolumeSource(
                                    name=f"{NAME}-config"
                                ),
                            ),
                            k8s.Volume(
                                name="music",
                                persistent_volume_claim=k8s.PersistentVolumeClaimVolumeSource(
                                    claim_name=LOCAL_CLAIM, read_only=True
                                ),
                            ),
                        ],
                    ),
                ),
            ),
        )

        k8s.KubeService(
            self,
            "service",
            metadata=k8s.ObjectMeta(name=NAME, namespace=ns, labels=labels),
            spec=k8s.ServiceSpec(
                selector=sel,
                ports=[
                    k8s.ServicePort(
                        name="http",
                        port=PORT,
                        target_port=k8s.IntOrString.from_string("http"),
                    )
                ],
            ),
        )
