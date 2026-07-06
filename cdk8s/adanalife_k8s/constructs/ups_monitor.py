"""UPS monitor — a NUT client that watches the APC BE600M1 over the network.

The UPS's RJ50/USB data cable is plugged into the Synology NAS, which runs the
NUT *server* (upsd) and is the unit physically wired to the battery. The minipc
can't see the UPS over USB (and Talos wouldn't let us install NUT on the host
anyway), so this pod is a NUT *client*: it talks to the Synology's upsd over the
LAN (TCP 3493) and reacts to battery state.

Synology's network-UPS-server requires the client to authenticate even for status
reads — an anonymous `upsc` gets `Error: Access denied`. The creds are Synology's
fixed, unchangeable public defaults (user `monuser`, password `secret`), good only
for reading UPS status on the LAN, so they're inline rather than in ESO. Pod
traffic to the NAS is masqueraded by Cilium to the minipc node IP
(192.168.40.111), the IP allowlisted on the Synology.

The reader (stdlib socket) logs in, does `GET VAR ups ups.status` (+ charge /
runtime), logs every transition, and — STAGE 2 — triggers a graceful node
shutdown when the battery is genuinely about to die.

STAGE 1 (shipped): observe-only logging.

STAGE 2 (this file): the graceful-shutdown trigger — on a sustained on-battery +
low-battery condition (`OB LB`, or estimated runtime below RUNTIME_THRESHOLD),
confirmed over CONFIRM_POLLS consecutive fast polls, run
`talosctl shutdown --nodes <node>` so the node powers off cleanly before the
battery dies. A clean shutdown protects etcd + the Talos STATE/OS partition from
hard-power-cut corruption (the kind of unclean crash that caused the 2026-06-15
outage), so the node comes back cleanly. Note it does NOT save the prod postgres
data while that DB is on an ephemeral local-path volume — durable storage is the
separate fix that protects the data (shipped: the T5 UserVolume); this protects
the cluster.

**ARMED.** `DRY_RUN=false`: the trigger executes the real shutdown. The
credential is the `ups-talosconfig` Secret, delivered by the ExternalSecret
emitted here (cluster store → SSM `/k8s/ups/talosconfig`) and minted with the
`os:operator` role (the narrowest Talos role that permits shutdown — no
config-write/admin), reaching the Talos API at <node>:50000. To stand down:
flip `DRY_RUN` back to "true" (log-only) — the optional Secret mount and the
manual-sync Argo Application remain as the other two gates for a fresh
environment where the SSM parameter is unseeded.

A raw-socket reader (vs `upsmon`) keeps the trigger logic explicit and auditable:
it only ever reads UPS vars, and the single action it can take is the one
`talosctl shutdown` call, gated by DRY_RUN. It runs unprivileged on a read-only
rootfs as a non-root user; `talosctl` is fetched by an initContainer (the Python
image doesn't ship it) into a shared volume.
"""

from __future__ import annotations

import imports.k8s as k8s
from constructs import Construct

from adanalife_k8s import eso
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
POLL_INTERVAL = "30"  # seconds between reads on utility power
POLL_INTERVAL_ONBATTERY = "10"  # faster reads while on battery (quicker reaction)
# The minipc Talos node — the control-plane / etcd / DB node this shuts down. The
# rpi5 worker isn't on this UPS, so it's deliberately out of scope.
TALOS_NODE = "192.168.40.111"
RUNTIME_THRESHOLD = "120"  # shut down once estimated runtime drops below this (s)
CONFIRM_POLLS = "2"  # require the trigger condition this many polls in a row
TALOSCONFIG_PATH = "/talos/talosconfig"  # mounted from the (optional) Secret
TALOSCTL_PATH = "/opt/talos/talosctl"  # placed by the initContainer
# ARMED — the trigger executes the real `talosctl shutdown`. Flip to "true" for
# log-only mode (it logs the command it WOULD run). See the module docstring.
DRY_RUN = "false"
# python:3.14-alpine — current latest stable, multi-arch (minipc is amd64). The
# reader is pure stdlib, so no NUT package or pip install is needed.
IMAGE = "python:3.14-alpine"
# Pinned to the cluster's Talos version (1.13.2). The initContainer fetches the
# client binary at pod start (the Python image doesn't ship it); a single
# long-lived pod fetches once. amd64 — the minipc's arch.
TALOSCTL_VERSION = "v1.13.2"
TALOSCTL_URL = (
    f"https://github.com/siderolabs/talos/releases/download/{TALOSCTL_VERSION}"
    "/talosctl-linux-amd64"
)
# The Secret holding the os:operator-scoped talosconfig, delivered by the
# ExternalSecret emitted in UpsMonitor (cluster store → SSM
# /k8s/ups/talosconfig). Mounted OPTIONALLY so a deploy without the seeded
# parameter (fresh env, DRY_RUN testing) still schedules.
TALOSCONFIG_SECRET = "ups-talosconfig"

# initContainer: fetch the pinned talosctl into the shared volume. stdlib urllib
# (the same Python image), so no extra tooling. Verified-by-pin, not checksum —
# acceptable for a LAN safety daemon; revisit if supply-chain hardening is wanted.
_FETCH_TALOSCTL = """\
import os
import urllib.request

url = os.environ["TALOSCTL_URL"]
dst = os.environ["TALOSCTL_PATH"]
print(f"fetching {url}", flush=True)
urllib.request.urlretrieve(url, dst)
os.chmod(dst, 0o755)
print(f"talosctl -> {dst}", flush=True)
"""

# The reader. Authenticates, reads ups.status + battery vars, logs every change,
# and on a sustained on-battery + low-battery (or low-runtime) condition runs the
# graceful shutdown — UNLESS DRY_RUN, in which case it only logs the command it
# would run. It issues at most one shutdown. Verified locally against a mock NUT
# server (auth + an on-battery/low-battery scenario).
_READER = """\
import datetime
import os
import socket
import subprocess
import time

SERVER = os.environ.get("NUT_SERVER", "127.0.0.1")
PORT = int(os.environ.get("NUT_PORT", "3493"))
UPS = os.environ.get("NUT_UPS", "ups")
USER = os.environ.get("NUT_USER", "")
PASSWORD = os.environ.get("NUT_PASS", "")
POLL_OK = int(os.environ.get("POLL_INTERVAL", "30"))
POLL_OB = int(os.environ.get("POLL_INTERVAL_ONBATTERY", "10"))
RUNTIME_FLOOR = int(os.environ.get("RUNTIME_THRESHOLD", "120"))
CONFIRM = int(os.environ.get("CONFIRM_POLLS", "2"))
NODE = os.environ.get("TALOS_NODE", "")
TALOSCONFIG = os.environ.get("TALOSCONFIG", "/talos/talosconfig")
TALOSCTL = os.environ.get("TALOSCTL", "/opt/talos/talosctl")
DRY_RUN = os.environ.get("DRY_RUN", "true").lower() != "false"
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
            if not cmd(f"USERNAME {USER}").startswith("OK"):
                raise RuntimeError("USERNAME rejected")
            if not cmd(f"PASSWORD {PASSWORD}").startswith("OK"):
                raise RuntimeError("PASSWORD rejected")
        out = {}
        for var in VARS:
            r = cmd(f"GET VAR {UPS} {var}")
            out[var] = r.split('"')[1] if r.startswith("VAR ") and '"' in r else ""
        return out
    finally:
        sock.close()


def shutdown_cmd():
    return [TALOSCTL, "--talosconfig", TALOSCONFIG, "shutdown", "--nodes", NODE]


log(
    f"ups-monitor STAGE 2 — graceful shutdown on OB+LB or runtime<{RUNTIME_FLOOR}s "
    f"(confirmed {CONFIRM}x). DRY_RUN={DRY_RUN} NODE={NODE or '(unset)'}"
)
confirm = 0
triggered = False
while True:
    interval = POLL_OK
    try:
        v = query()
        status = v.get("ups.status", "")
        tokens = status.split()
        on_batt = "OB" in tokens
        low_batt = "LB" in tokens
        rt = v.get("battery.runtime", "")
        runtime = int(rt) if rt.isdigit() else None
        line = (
            f"ups.status={status or '?'} charge={v.get('battery.charge') or '?'}% "
            f"runtime={rt or '?'}s"
        )
        if on_batt:
            interval = POLL_OB
            runtime_low = runtime is not None and runtime < RUNTIME_FLOOR
            confirm = confirm + 1 if (low_batt or runtime_low) else 0
            if confirm >= CONFIRM and not triggered:
                reason = "OB+LB" if low_batt else f"runtime<{RUNTIME_FLOOR}s"
                cmd_str = " ".join(shutdown_cmd())
                if DRY_RUN or not NODE:
                    log(f"!! TRIGGER ({reason}) x{confirm} — DRY_RUN, would run: {cmd_str}")
                else:
                    log(f"!! TRIGGER ({reason}) x{confirm} — ARMED, running: {cmd_str}")
                    triggered = True
                    try:
                        r = subprocess.run(
                            shutdown_cmd(), capture_output=True, text=True, timeout=60
                        )
                        log(f"talosctl rc={r.returncode} out={r.stdout.strip()!r} err={r.stderr.strip()!r}")
                    except Exception as e:
                        log(f"talosctl FAILED: {e}")
        else:
            confirm = 0
        log(line + (f" [on-battery confirm={confirm}/{CONFIRM}]" if on_batt else ""))
    except Exception as e:
        log(f"ups.status=UNREACHABLE: {e}")
    time.sleep(interval)
"""


class UpsMonitor(Construct):
    """The NUT-client UPS monitor + its reader ConfigMap. Cluster-singleton (one
    minipc, one UPS) in its own `ups` namespace — env-agnostic, authored once and
    delivered by a dedicated Argo Application (see constructs/argocd.py).
    DISARMED by default (DRY_RUN + optional cert mount + manual sync)."""

    def __init__(self, scope: Construct, id: str = NAME):
        super().__init__(scope, id)
        labels = meta_labels(NAME, part_of="infra")
        sel = selector(NAME)

        k8s.KubeConfigMap(
            self,
            "reader",
            metadata=k8s.ObjectMeta(name=NAME, namespace=NAMESPACE, labels=labels),
            data={"nutread.py": _READER, "fetch-talosctl.py": _FETCH_TALOSCTL},
        )

        # The shutdown credential. Cluster store (not a namespaced SecretStore):
        # the ups namespace has no eso-aws-credentials of its own, and one
        # parameter doesn't justify bootstrapping one.
        eso.external_secret(
            self,
            "talosconfig-secret",
            name=TALOSCONFIG_SECRET,
            namespace=NAMESPACE,
            store=("aws-parameterstore-cluster", "ClusterSecretStore"),
            labels=labels,
            data=[eso.ESData(secret_key="talosconfig", key="/k8s/ups/talosconfig")],
        )

        # Shared security floor for both containers: non-root, no privilege, no
        # writable rootfs, all caps dropped. The pod can do exactly two things —
        # read UPS vars and (when armed) make one talosctl Shutdown call.
        secctx = k8s.SecurityContext(
            allow_privilege_escalation=False,
            run_as_non_root=True,
            run_as_user=65534,  # nobody
            read_only_root_filesystem=True,
            capabilities=k8s.Capabilities(drop=["ALL"]),
        )
        script_mount = k8s.VolumeMount(name="script", mount_path="/app", read_only=True)
        bin_mount = k8s.VolumeMount(name="talosctl", mount_path="/opt/talos")

        init = k8s.Container(
            name="fetch-talosctl",
            image=IMAGE,
            command=["python3", "/app/fetch-talosctl.py"],
            env=[
                k8s.EnvVar(name="TALOSCTL_URL", value=TALOSCTL_URL),
                k8s.EnvVar(name="TALOSCTL_PATH", value=TALOSCTL_PATH),
            ],
            security_context=secctx,
            volume_mounts=[script_mount, bin_mount],
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
                k8s.EnvVar(
                    name="POLL_INTERVAL_ONBATTERY", value=POLL_INTERVAL_ONBATTERY
                ),
                k8s.EnvVar(name="TALOS_NODE", value=TALOS_NODE),
                k8s.EnvVar(name="RUNTIME_THRESHOLD", value=RUNTIME_THRESHOLD),
                k8s.EnvVar(name="CONFIRM_POLLS", value=CONFIRM_POLLS),
                k8s.EnvVar(name="TALOSCONFIG", value=TALOSCONFIG_PATH),
                k8s.EnvVar(name="TALOSCTL", value=TALOSCTL_PATH),
                # The single arming gate in the pod spec. "true" = log-only.
                k8s.EnvVar(name="DRY_RUN", value=DRY_RUN),
                k8s.EnvVar(name="HOME", value="/tmp"),
            ],
            security_context=secctx,
            resources=k8s.ResourceRequirements(
                requests={
                    "cpu": k8s.Quantity.from_string("10m"),
                    "memory": k8s.Quantity.from_string("32Mi"),
                },
                # Headroom for talosctl (a ~50MB Go binary) when it runs.
                limits={"memory": k8s.Quantity.from_string("128Mi")},
            ),
            volume_mounts=[
                script_mount,
                k8s.VolumeMount(
                    name="talosctl", mount_path="/opt/talos", read_only=True
                ),
                k8s.VolumeMount(
                    name="talosconfig", mount_path="/talos", read_only=True
                ),
                k8s.VolumeMount(name="home", mount_path="/tmp"),
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
                            seccomp_profile=k8s.SeccompProfile(type="RuntimeDefault"),
                            # Group-own the emptyDirs so the non-root user can write
                            # the fetched talosctl + $HOME.
                            fs_group=65534,
                        ),
                        init_containers=[init],
                        containers=[container],
                        volumes=[
                            k8s.Volume(
                                name="script",
                                config_map=k8s.ConfigMapVolumeSource(name=NAME),
                            ),
                            k8s.Volume(
                                name="talosctl", empty_dir=k8s.EmptyDirVolumeSource()
                            ),
                            k8s.Volume(
                                name="home", empty_dir=k8s.EmptyDirVolumeSource()
                            ),
                            # OPTIONAL: absent until arming provisions the Secret, so
                            # DRY_RUN deploys need no credential.
                            k8s.Volume(
                                name="talosconfig",
                                secret=k8s.SecretVolumeSource(
                                    secret_name=TALOSCONFIG_SECRET, optional=True
                                ),
                            ),
                        ],
                    ),
                ),
            ),
        )
