"""UPS monitor — a NUT client that watches the APC BE600M1 over the network.

The UPS's RJ50/USB data cable is plugged into the Synology NAS, which runs the
NUT *server* (upsd) and is the unit physically wired to the battery. The minipc
can't see the UPS over USB (and Talos wouldn't let us install NUT on the host
anyway), so this pod is a NUT *client*: it talks to the Synology's upsd over the
LAN (TCP 3493) and reacts to battery state. Synology's network-UPS-server creds
are fixed public defaults (ups@<nas>, monuser/secret) and unchangeable in DSM —
but status reads via `upsc` are anonymous, so this observe-only stage needs no
credentials at all.

STAGE 1 (this file): OBSERVE-ONLY. A `upsc` poll loop that only *reads* UPS
status and logs every transition (ONLINE -> ONBATT -> LOWBATT). It has no
shutdown capability — no `talosctl`, no Talos PKI, no privileged/hostPID — so it
physically cannot reboot the node. That matters: the prod postgres still lives on
an ephemeral local-path volume, and a reboot loses it, so arming an auto-shutdown
now would be the very failure we're guarding against. This stage exists to verify
the minipc<->Synology NUT wiring end-to-end, safely.

STAGE 2 (later, gated on durable prod storage): swap the poll loop for a real
shutdown trigger — on a sustained `OB LB` (on-battery + low-battery), run
`talosctl shutdown --nodes 192.168.40.111` for a graceful poweroff before the
battery dies. That needs a tightly-scoped talosconfig Secret mounted in, and is a
deliberate one-line flip of the command below + the manual Argo sync.

`instantlinux/nut-upsd` is a NUT *server* image, but it ships the full NUT
package — we use it purely as the box that carries the `upsc` client binary and
override its entrypoint with our own poll loop. `upsc` is a standalone client
that needs no local upsd/driver config, so the image's server machinery is inert.
"""

from __future__ import annotations

import imports.k8s as k8s
from constructs import Construct

from adanalife_k8s.naming import meta_labels, selector

NAME = "ups-monitor"
NAMESPACE = "ups"
# NUT server == the Synology NAS (the unit wired to the UPS). Fixed public
# defaults: UPS name "ups", upsd on 3493 (see module docstring).
NUT_SERVER = "192.168.40.100"
NUT_PORT = "3493"
NUT_UPS = "ups"
POLL_INTERVAL = "30"  # seconds between status reads
# instantlinux/nut-upsd 2.8.3-r4 — current latest stable, multi-arch (minipc is
# amd64). Pulled from Docker Hub: a single long-lived pod pulls once and caches,
# so the per-image rate limit that drives the GHCR-mirror ADR doesn't bite here.
# (If the minipc ever feels Hub limits, mirror to ghcr.io/adanalife/mirror/ per
# vault/decisions/ghcr-base-image-mirrors.md and repoint.)
IMAGE = "instantlinux/nut-upsd:2.8.3-r4"

# Observe-only poll loop. `upsc <ups>@<host>:<port> <var>` reads one variable
# anonymously; we read ups.status and log every change (plus charge/runtime for
# context). A read failure (server down, not yet allowlisted) is logged and the
# loop continues — it never exits on a transient, and it never acts on state.
_WATCH = """\
set -u
echo "ups-monitor: OBSERVE-ONLY — polling ${NUT_UPS}@${NUT_SERVER}:${NUT_PORT} every ${POLL_INTERVAL}s (read-only; no node-control capability)"
TARGET="${NUT_UPS}@${NUT_SERVER}:${NUT_PORT}"
last=""
while true; do
  if status="$(upsc "$TARGET" ups.status 2>&1)"; then
    charge="$(upsc "$TARGET" battery.charge 2>/dev/null || echo '?')"
    runtime="$(upsc "$TARGET" battery.runtime 2>/dev/null || echo '?')"
  else
    status="UNREACHABLE: ${status}"
    charge="?"; runtime="?"
  fi
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ "$status" != "$last" ]; then
    echo "${ts} ups.status CHANGED: '${last:-<none>}' -> '${status}' (charge=${charge}% runtime=${runtime}s)"
    last="$status"
  else
    echo "${ts} ups.status=${status} charge=${charge}% runtime=${runtime}s"
  fi
  sleep "${POLL_INTERVAL}"
done
"""


class UpsMonitor(Construct):
    """The observe-only NUT-client Deployment. Cluster-singleton (one minipc, one
    UPS) in its own `ups` namespace — env-agnostic, so it's authored once and
    delivered by a dedicated Argo Application (see constructs/argocd.py)."""

    def __init__(self, scope: Construct, id: str = NAME):
        super().__init__(scope, id)
        labels = meta_labels(NAME, part_of="infra")
        sel = selector(NAME)

        container = k8s.Container(
            name=NAME,
            image=IMAGE,
            # Override the image's server entrypoint with our read-only poll loop.
            command=["/bin/sh", "-c"],
            args=[_WATCH],
            env=[
                k8s.EnvVar(name="NUT_SERVER", value=NUT_SERVER),
                k8s.EnvVar(name="NUT_PORT", value=NUT_PORT),
                k8s.EnvVar(name="NUT_UPS", value=NUT_UPS),
                k8s.EnvVar(name="POLL_INTERVAL", value=POLL_INTERVAL),
            ],
            # A pure network reader: no root, no privilege, no writable rootfs,
            # no host namespaces. This security floor is itself the observe-only
            # guarantee — there's no path from here to a node reboot.
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
                    "memory": k8s.Quantity.from_string("16Mi"),
                },
                limits={"memory": k8s.Quantity.from_string("64Mi")},
            ),
        )

        k8s.KubeDeployment(
            self,
            "deployment",
            metadata=k8s.ObjectMeta(name=NAME, namespace=NAMESPACE, labels=labels),
            spec=k8s.DeploymentSpec(
                replicas=1,
                # Singleton — never run two pollers side by side during a rollout.
                strategy=k8s.DeploymentStrategy(type="Recreate"),
                selector=k8s.LabelSelector(match_labels=sel),
                template=k8s.PodTemplateSpec(
                    metadata=k8s.ObjectMeta(labels=sel),
                    spec=k8s.PodSpec(
                        security_context=k8s.PodSecurityContext(
                            seccomp_profile=k8s.SeccompProfile(type="RuntimeDefault")
                        ),
                        containers=[container],
                    ),
                ),
            ),
        )
