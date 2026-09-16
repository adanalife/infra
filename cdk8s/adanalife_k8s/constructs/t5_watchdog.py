"""T5 watchdog — auto-reboots the minipc when /var/mnt/data stops answering.

The Samsung T5 that carries the `u-data` UserVolume (every local-path PV: both
postgreses, playout's corpus, VictoriaMetrics, the ARC work dir) has dropped off
the USB bus four times. A drop shuts down the XFS, and Talos has no remount verb
and will not re-bind a UserVolume whose device node changed — so the only fix is
a node reboot. On 2026-09-13 the node sat with every data-backed pod in
`CreateContainerError` for **5h28m** waiting for a human to type `talosctl
reboot`; the reboot itself took 2 minutes to a mounted volume.

This closes that gap: probe the volume, and when it has been unreadable for
CONFIRM_POLLS consecutive reads, issue the reboot.

**The probe goes over the Talos API, not a mount.** `talosctl list /var/mnt/data`
does the readdir host-side, so this pod holds no hostPath and cannot itself land
in the `CreateContainerError` that every T5-mounting pod hits during the exact
fault it exists to catch. A failure is either the command erroring (EIO from a
shut-down XFS) or an empty listing (the device re-enumerated and the mount is
gone) — the two shapes the incidents produced.

**Two guards against a reboot loop**, both from a single source of truth — the
process's own monotonic clock, which resets with the pod on every boot:

1. nothing fires in the first STARTUP_GRACE seconds of the process, so a node
   that came back with the drive still sick cannot immediately reboot again;
2. a successful reboot latches; a failed one does not, so a timed-out `talosctl`
   retries on the next poll rather than abandoning the node.

Together those bound the worst case to one reboot per STARTUP_GRACE.

**ARMED.** `DRY_RUN=false`: the trigger runs the real `talosctl reboot`. The
credential is the `t5-watchdog-talosconfig` Secret, delivered by the
ExternalSecret emitted here from SSM `/k8s/ups/talosconfig` — the same
`os:operator` talosconfig the UPS monitor holds (the narrowest Talos role that
permits reboot; no config-write/admin). Sharing it is deliberate: the scope is
identical. To stand down: flip `DRY_RUN` to "true" (log-only) — the optional
Secret mount and the manual-sync Argo Application remain as the other two
gates.

The script self-checks: `python3 /app/t5probe.py --selftest` asserts the trigger
boundaries without touching the node, and is what the unit test runs.
"""

from __future__ import annotations

import imports.k8s as k8s
from constructs import Construct

from adanalife_k8s import eso
from adanalife_k8s.constructs.ups_monitor import _FETCH_TALOSCTL
from adanalife_k8s.naming import (
    CONFIG_HASH_ANNOTATION,
    config_hash,
    meta_labels,
    selector,
)

NAME = "t5-watchdog"
NAMESPACE = "node-watchdog"
# The minipc Talos node — the one that carries the T5. The rpi5 worker has no
# UserVolume, so it's deliberately out of scope.
TALOS_NODE = "192.168.40.111"
# The UserVolume mount point (u-data), where local-path provisions every PV.
PROBE_PATH = "/var/mnt/data"
POLL_INTERVAL = "20"  # seconds between probes
# Consecutive failed probes before the reboot. 3 x 20s ≈ a minute of sustained
# fault — long enough that a single slow API read can't reboot prod, short
# enough to be irrelevant next to the 5h28m it replaces.
CONFIRM_POLLS = "3"
# No reboot in the first 15 minutes of this process's life. The pod restarts
# with the node, so this doubles as the once-per-15-minutes loop guard.
STARTUP_GRACE = "900"
PROBE_TIMEOUT = "30"  # seconds allowed for a single `talosctl list`
REBOOT_TIMEOUT = "120"  # seconds allowed for a single `talosctl reboot`
TALOSCONFIG_PATH = "/talos/talosconfig"  # mounted from the (optional) Secret
TALOSCTL_PATH = "/opt/talos/talosctl"  # placed by the initContainer
# ARMED — the trigger executes the real `talosctl reboot`. Flip to "true" for
# log-only mode (it logs the command it WOULD run). See the module docstring.
DRY_RUN = "false"
# python:3.14-alpine — the probe is pure stdlib, so no pip install is needed.
IMAGE = "python:3.14-alpine"
# Pinned to the cluster's Talos version. The initContainer fetches the client
# binary at pod start (the Python image doesn't ship it); a single long-lived
# pod fetches once. amd64 — the minipc's arch.
TALOSCTL_VERSION = "v1.14.0"
TALOSCTL_URL = (
    f"https://github.com/siderolabs/talos/releases/download/{TALOSCTL_VERSION}"
    "/talosctl-linux-amd64"
)
# Shares the UPS monitor's os:operator talosconfig (same node, same role, and
# reboot is a subset of what shutdown already permits). Mounted OPTIONALLY so a
# deploy without the seeded parameter still schedules.
TALOSCONFIG_SECRET = "t5-watchdog-talosconfig"
TALOSCONFIG_SSM_KEY = "/k8s/ups/talosconfig"

_PROBE = """\
import datetime
import os
import subprocess
import sys
import time

NODE = os.environ.get("TALOS_NODE", "")
PATH = os.environ.get("PROBE_PATH", "/var/mnt/data")
POLL = int(os.environ.get("POLL_INTERVAL", "20"))
CONFIRM = int(os.environ.get("CONFIRM_POLLS", "3"))
GRACE = float(os.environ.get("STARTUP_GRACE", "900"))
PROBE_TIMEOUT = int(os.environ.get("PROBE_TIMEOUT", "30"))
REBOOT_TIMEOUT = int(os.environ.get("REBOOT_TIMEOUT", "120"))
TALOSCONFIG = os.environ.get("TALOSCONFIG", "/talos/talosconfig")
TALOSCTL = os.environ.get("TALOSCTL", "/opt/talos/talosctl")
DRY_RUN = os.environ.get("DRY_RUN", "true").lower() != "false"
START = time.monotonic()


def log(msg):
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"{ts} {msg}", flush=True)


def talos(*args, timeout):
    return subprocess.run(
        [TALOSCTL, "--talosconfig", TALOSCONFIG, "--nodes", NODE, *args],
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def entries(stdout):
    # One line per dirent, including `.` for the directory itself. A live
    # UserVolume always holds the local-path PV directories, so a listing with
    # nothing but `.` means the mount is gone — the shape the 2026-09-13
    # re-enumeration produced, which reads as success to a returncode-only check.
    #
    # Filter by content, never by position: `talosctl list` prints the NODE/NAME
    # header only when asked for more than one node, and this probe asks for one.
    # Dropping a fixed first line would undercount a headerless listing by one,
    # and at one entry that reads as an empty mount — i.e. it reboots prod.
    lines = (ln.strip() for ln in stdout.splitlines() if ln.strip())
    return [ln for ln in lines if ln.split()[-1] not in (".", "..", "NAME")]


def probe():
    # (healthy, detail). Unreadable and empty both count as a fault.
    try:
        r = talos("list", PATH, timeout=PROBE_TIMEOUT)
    except Exception as e:
        return False, f"list FAILED: {e}"
    if r.returncode != 0:
        return False, f"list rc={r.returncode} err={r.stderr.strip()!r}"
    found = entries(r.stdout)
    if not found:
        return False, "list returned no entries — mount is gone"
    return True, f"{len(found)} entries"


def may_reboot(fails, elapsed, triggered):
    # The whole trigger decision, in one place so the self-check can pin it.
    return fails >= CONFIRM and elapsed >= GRACE and not triggered


def reboot(reason):
    # True only on success — a failure leaves the trigger UNLATCHED so the next
    # poll retries rather than leaving the node wedged.
    cmd = f"{TALOSCTL} --talosconfig {TALOSCONFIG} --nodes {NODE} reboot"
    if DRY_RUN or not NODE:
        log(f"!! TRIGGER ({reason}) — DRY_RUN, would run: {cmd}")
        return False
    log(f"!! TRIGGER ({reason}) — ARMED, running: {cmd}")
    try:
        r = talos("reboot", timeout=REBOOT_TIMEOUT)
        log(f"talosctl rc={r.returncode} out={r.stdout.strip()!r} err={r.stderr.strip()!r}")
        if r.returncode == 0:
            return True
        log("talosctl returned non-zero — will retry next poll")
    except Exception as e:
        log(f"talosctl FAILED: {e} — will retry next poll")
    return False


def selftest():
    # Trigger boundaries, no node required.
    assert not may_reboot(CONFIRM - 1, GRACE + 1, False), "fires below CONFIRM"
    assert not may_reboot(CONFIRM, GRACE - 1, False), "fires inside the startup grace"
    assert not may_reboot(CONFIRM, GRACE + 1, True), "fires twice after latching"
    assert may_reboot(CONFIRM, GRACE + 1, False), "never fires"
    # The real single-node shape: no header, `.` first, then the dirents.
    assert entries(".\\narc-work\\nlocal-path-provisioner\\n") == [
        "arc-work",
        "local-path-provisioner",
    ]
    # A single real entry must not be eaten as a header — that reads as an empty
    # mount and reboots prod.
    assert entries(".\\nlocal-path-provisioner\\n") == ["local-path-provisioner"]
    # The multi-node shape, header and all, in case --nodes ever grows.
    assert entries("NODE   NAME\\n1.2.3.4   .\\n1.2.3.4   pvc-abc\\n") == [
        "1.2.3.4   pvc-abc"
    ]
    # A dead mount: the directory itself and nothing under it.
    assert entries(".\\n") == []
    assert entries("") == []
    print("selftest ok", flush=True)


def main():
    log(
        f"t5-watchdog — reboot {NODE or '(unset)'} after {CONFIRM} consecutive "
        f"unreadable probes of {PATH} (every {POLL}s, no action for the first "
        f"{GRACE:.0f}s of uptime). DRY_RUN={DRY_RUN}"
    )
    fails = 0
    triggered = False
    while True:
        healthy, detail = probe()
        fails = 0 if healthy else fails + 1
        elapsed = time.monotonic() - START
        log(
            f"{PATH} {'ok' if healthy else 'FAULT'}: {detail}"
            + (f" [{fails}/{CONFIRM}]" if fails else "")
        )
        if may_reboot(fails, elapsed, triggered):
            triggered = reboot(f"{PATH} unreadable x{fails}")
        elif fails >= CONFIRM and elapsed < GRACE:
            log(f"holding: {elapsed:.0f}s uptime is inside the {GRACE:.0f}s grace")
        time.sleep(POLL)


if "--selftest" in sys.argv:
    selftest()
else:
    main()
"""


class T5Watchdog(Construct):
    """The T5 watchdog + its probe ConfigMap. Cluster-singleton (one minipc, one
    T5) in its own `node-watchdog` namespace — env-agnostic, authored once and
    delivered by a dedicated Argo Application (see constructs/argocd.py)."""

    def __init__(self, scope: Construct, id: str = NAME):
        super().__init__(scope, id)
        labels = meta_labels(NAME, part_of="infra")
        sel = selector(NAME)

        scripts = {"t5probe.py": _PROBE, "fetch-talosctl.py": _FETCH_TALOSCTL}
        k8s.KubeConfigMap(
            self,
            "probe",
            metadata=k8s.ObjectMeta(name=NAME, namespace=NAMESPACE, labels=labels),
            data=scripts,
        )

        # The reboot credential. Cluster store (not a namespaced SecretStore):
        # this namespace has no eso-aws-credentials of its own, and one
        # parameter doesn't justify bootstrapping one.
        eso.external_secret(
            self,
            "talosconfig-secret",
            name=TALOSCONFIG_SECRET,
            namespace=NAMESPACE,
            store=("aws-parameterstore-cluster", "ClusterSecretStore"),
            labels=labels,
            data=[eso.ESData(secret_key="talosconfig", key=TALOSCONFIG_SSM_KEY)],
        )

        # Shared security floor for both containers: non-root, no privilege, no
        # writable rootfs, all caps dropped. The pod can do exactly two things —
        # list one directory over the Talos API, and (when armed) reboot.
        secctx = k8s.SecurityContext(
            allow_privilege_escalation=False,
            run_as_non_root=True,
            run_as_user=65534,  # nobody
            read_only_root_filesystem=True,
            capabilities=k8s.Capabilities(drop=["ALL"]),
        )
        script_mount = k8s.VolumeMount(name="script", mount_path="/app", read_only=True)

        init = k8s.Container(
            name="fetch-talosctl",
            image=IMAGE,
            command=["python3", "/app/fetch-talosctl.py"],
            env=[
                k8s.EnvVar(name="TALOSCTL_URL", value=TALOSCTL_URL),
                k8s.EnvVar(name="TALOSCTL_PATH", value=TALOSCTL_PATH),
            ],
            security_context=secctx,
            volume_mounts=[
                script_mount,
                k8s.VolumeMount(name="talosctl", mount_path="/opt/talos"),
            ],
        )

        container = k8s.Container(
            name=NAME,
            image=IMAGE,
            command=["python3", "/app/t5probe.py"],
            env=[
                k8s.EnvVar(name="TALOS_NODE", value=TALOS_NODE),
                k8s.EnvVar(name="PROBE_PATH", value=PROBE_PATH),
                k8s.EnvVar(name="POLL_INTERVAL", value=POLL_INTERVAL),
                k8s.EnvVar(name="CONFIRM_POLLS", value=CONFIRM_POLLS),
                k8s.EnvVar(name="STARTUP_GRACE", value=STARTUP_GRACE),
                k8s.EnvVar(name="PROBE_TIMEOUT", value=PROBE_TIMEOUT),
                k8s.EnvVar(name="REBOOT_TIMEOUT", value=REBOOT_TIMEOUT),
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
                # Singleton — two watchdogs could double-reboot during a rollout.
                strategy=k8s.DeploymentStrategy(type="Recreate"),
                selector=k8s.LabelSelector(match_labels=sel),
                template=k8s.PodTemplateSpec(
                    # Python reads the scripts once at startup, so the digest is
                    # what rolls the probe when the ConfigMap changes.
                    metadata=k8s.ObjectMeta(
                        labels=sel,
                        annotations={CONFIG_HASH_ANNOTATION: config_hash(scripts)},
                    ),
                    spec=k8s.PodSpec(
                        # PSA `restricted`: runAsNonRoot + the uid sit on both
                        # containers (secctx above), which is where admission
                        # reads them; the pod level carries what only it can.
                        security_context=k8s.PodSecurityContext(
                            seccomp_profile=k8s.SeccompProfile(type="RuntimeDefault"),
                            # Group-own the emptyDirs so the non-root user can
                            # write the fetched talosctl + $HOME.
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
                            # OPTIONAL: absent until ESO syncs it, so a deploy
                            # without the seeded parameter still schedules.
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
