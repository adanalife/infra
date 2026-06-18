"""UPS monitor — a NUT client that watches the APC BE600M1 over the network.

The UPS's RJ50/USB data cable is plugged into the Synology NAS, which runs the
NUT *server* (upsd) and is the unit physically wired to the battery. The minipc
can't see the UPS over USB (and Talos wouldn't let us install NUT on the host
anyway), so this pod is a NUT *client*: it talks to the Synology's upsd over the
LAN (TCP 3493) and reacts to battery state.

Synology's network-UPS-server requires the client to authenticate even for status
reads — an anonymous `upsc` gets `Error: Access denied` (confirmed on the live
NAS, #761/#762). The creds are Synology's fixed, unchangeable public defaults
(user `monuser`, password `secret`), documented everywhere and good only for
reading UPS status on the LAN, so they're not a real secret — they live inline
below rather than in ESO. Pod traffic to the NAS is masqueraded by Cilium to the
minipc node IP (192.168.40.111), which is the IP allowlisted on the Synology.

STAGE 1 (this file): OBSERVE-ONLY. A tiny stdlib-socket NUT client that logs in,
does `GET VAR ups ups.status` (+ charge/runtime), and logs every transition
(ONLINE -> ONBATT -> LOWBATT). It *only reads* — there is no shutdown command, no
`talosctl`, no Talos PKI, no privileged/hostPID — so it physically cannot reboot
the node. That matters: the prod postgres still lives on an ephemeral local-path
volume, and a reboot loses it, so arming an auto-shutdown now would be the very
failure we're guarding against. This stage verifies the minipc<->Synology NUT
wiring safely. It logs the raw server response on any error, so a misconfig
surfaces in the pod logs rather than silently.

STAGE 2 (later, gated on durable prod storage): add a real shutdown trigger — on
a sustained `OB LB` (on-battery + low-battery), run `talosctl shutdown --nodes
192.168.40.111` for a graceful poweroff before the battery dies. That needs a
tightly-scoped talosconfig Secret mounted in, and is a deliberate change plus the
manual Argo sync.

A raw-socket reader (vs `upsmon`) keeps stage 1 dead simple and observe-only by
construction: there's no shutdown machinery to disarm, it runs unprivileged on a
read-only rootfs as a non-root user, and the NUT wire protocol is a handful of
newline-delimited commands. `upsmon` (with its proper FSD handling) is the
natural choice when stage 2 arms the shutdown.
"""

from __future__ import annotations

import imports.k8s as k8s
from constructs import Construct

from adanalife_k8s.naming import meta_labels, selector

NAME = "ups-monitor"
NAMESPACE = "ups"
# NUT server == the Synology NAS (the unit wired to the UPS). Fixed public
# defaults: UPS name "ups", upsd on 3493, creds monuser/secret (see docstring).
NUT_SERVER = "192.168.40.100"
NUT_PORT = "3493"
NUT_UPS = "ups"
NUT_USER = "monuser"
NUT_PASS = "secret"  # Synology's fixed public default — not a real secret
POLL_INTERVAL = "30"  # seconds between status reads
# python:3.14-alpine — current latest stable, multi-arch (minipc is amd64). The
# reader is pure stdlib (socket), so no NUT package or pip install is needed.
# Pulled from Docker Hub: a single long-lived pod pulls once and caches, so the
# per-image rate limit that drives the GHCR-mirror ADR doesn't bite here. (If the
# minipc ever feels Hub limits, mirror to ghcr.io/adanalife/mirror/ per
# vault/decisions/ghcr-base-image-mirrors.md and repoint.)
IMAGE = "python:3.14-alpine"

# The observe-only reader. Authenticates (USERNAME/PASSWORD), reads ups.status +
# battery vars via `GET VAR`, logs every change. It NEVER issues a write/command
# (no INSTCMD/SET), so it cannot affect the UPS or the node. On any error it logs
# the raw server response, so a misconfig (wrong creds, wrong UPS name, ACL) is
# visible in the pod logs. Verified locally against a mock NUT auth server.
_READER = """\
import datetime
import os
import socket
import time

SERVER = os.environ.get("NUT_SERVER", "127.0.0.1")
PORT = int(os.environ.get("NUT_PORT", "3493"))
UPS = os.environ.get("NUT_UPS", "ups")
USER = os.environ.get("NUT_USER", "")
PASSWORD = os.environ.get("NUT_PASS", "")
INTERVAL = int(os.environ.get("POLL_INTERVAL", "30"))
VARS = ("ups.status", "battery.charge", "battery.runtime")


def log(msg):
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"{ts} {msg}", flush=True)


def query():
    sock = socket.create_connection((SERVER, PORT), timeout=10)
    try:
        rf = sock.makefile("r", encoding="utf-8", newline="\\n")

        def cmd(line):
            sock.sendall((line + "\\n").encode())
            return rf.readline().strip()

        if USER:
            r = cmd(f"USERNAME {USER}")
            if not r.startswith("OK"):
                raise RuntimeError(f"USERNAME rejected: {r}")
            r = cmd(f"PASSWORD {PASSWORD}")
            if not r.startswith("OK"):
                raise RuntimeError(f"PASSWORD rejected: {r}")
        out = {}
        for var in VARS:
            r = cmd(f"GET VAR {UPS} {var}")
            out[var] = r.split('"')[1] if r.startswith("VAR ") and '"' in r else f"<{r}>"
        try:
            cmd("LOGOUT")
        except Exception:
            pass
        return out
    finally:
        sock.close()


log(
    f"ups-monitor: OBSERVE-ONLY — reading {UPS}@{SERVER}:{PORT} as "
    f"'{USER or '(anon)'}' every {INTERVAL}s (read-only; no node-control capability)"
)
last = None
while True:
    try:
        v = query()
        status = v.get("ups.status", "?")
        line = (
            f"ups.status={status} charge={v.get('battery.charge', '?')}% "
            f"runtime={v.get('battery.runtime', '?')}s"
        )
    except Exception as e:
        status = f"UNREACHABLE: {e}"
        line = f"ups.status={status}"
    if status != last:
        log(f"CHANGED: '{last}' -> {line}")
        last = status
    else:
        log(line)
    time.sleep(INTERVAL)
"""


class UpsMonitor(Construct):
    """The observe-only NUT-client Deployment + its reader ConfigMap.
    Cluster-singleton (one minipc, one UPS) in its own `ups` namespace —
    env-agnostic, so it's authored once and delivered by a dedicated Argo
    Application (see constructs/argocd.py)."""

    def __init__(self, scope: Construct, id: str = NAME):
        super().__init__(scope, id)
        labels = meta_labels(NAME, part_of="infra")
        sel = selector(NAME)

        k8s.KubeConfigMap(
            self,
            "reader",
            metadata=k8s.ObjectMeta(name=NAME, namespace=NAMESPACE, labels=labels),
            data={"nutread.py": _READER},
        )

        container = k8s.Container(
            name=NAME,
            image=IMAGE,
            command=["python3", "/app/nutread.py"],
            env=[
                k8s.EnvVar(name="NUT_SERVER", value=NUT_SERVER),
                k8s.EnvVar(name="NUT_PORT", value=NUT_PORT),
                k8s.EnvVar(name="NUT_UPS", value=NUT_UPS),
                k8s.EnvVar(name="NUT_USER", value=NUT_USER),
                k8s.EnvVar(name="NUT_PASS", value=NUT_PASS),
                k8s.EnvVar(name="POLL_INTERVAL", value=POLL_INTERVAL),
            ],
            # A pure network reader: no root, no privilege, no writable rootfs,
            # no host namespaces. This security floor is itself the observe-only
            # guarantee — there's no path from here to a node reboot. (Python
            # doesn't cache bytecode for a directly-run script, so a read-only
            # rootfs + read-only script mount need nothing writable.)
            security_context=k8s.SecurityContext(
                allow_privilege_escalation=False,
                run_as_non_root=True,
                run_as_user=65534,  # nobody
                read_only_root_filesystem=True,
                capabilities=k8s.Capabilities(drop=["ALL"]),
            ),
            resources=k8s.ResourceRequirements(
                requests={
                    "cpu": k8s.Quantity.from_string("10m"),
                    "memory": k8s.Quantity.from_string("32Mi"),
                },
                limits={"memory": k8s.Quantity.from_string("64Mi")},
            ),
            volume_mounts=[
                k8s.VolumeMount(name="script", mount_path="/app", read_only=True)
            ],
        )

        k8s.KubeDeployment(
            self,
            "deployment",
            metadata=k8s.ObjectMeta(name=NAME, namespace=NAMESPACE, labels=labels),
            spec=k8s.DeploymentSpec(
                replicas=1,
                # Singleton — never run two readers side by side during a rollout.
                strategy=k8s.DeploymentStrategy(type="Recreate"),
                selector=k8s.LabelSelector(match_labels=sel),
                template=k8s.PodTemplateSpec(
                    metadata=k8s.ObjectMeta(labels=sel),
                    spec=k8s.PodSpec(
                        security_context=k8s.PodSecurityContext(
                            seccomp_profile=k8s.SeccompProfile(type="RuntimeDefault")
                        ),
                        containers=[container],
                        volumes=[
                            k8s.Volume(
                                name="script",
                                config_map=k8s.ConfigMapVolumeSource(name=NAME),
                            )
                        ],
                    ),
                ),
            ),
        )
