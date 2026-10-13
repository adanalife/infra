"""Kernel-log shipper — streams the node's kmsg into Loki via pod stdout.

The minipc's kernel log is where a USB/storage fault actually announces itself,
and until this existed nothing alerted on it. On 2026-09-13 the T5 dropped off
the bus at 07:32:43Z with `usb 2-1: USB disconnect` → `XFS (sda1): log I/O error
-19`; the only alert that fired keyed off *pod* logs downstream of the fault, so
it could not tell a T5 drop from an NFS hiccup and went NoData once the affected
pods stopped logging.

Shape: one pod running `talosctl dmesg --follow --tail` against the node's API,
printing to stdout. The k8s-monitoring `alloy-logs` DaemonSet already scrapes
every pod's stdout into Grafana Cloud Loki, so no new receiver, no new shipper
and no protocol work — the lines arrive labelled like any other workload and the
alert rules key off them.

Deliberately NOT Talos's `KmsgLogConfig`, which would push kmsg to a listener:
it needs a control-plane `talosctl apply-config` (a certSAN edit took both
Postgreses down on 2026-06-15), and Alloy has no generic raw-TCP line source, so
terminating its JSON stream would mean adding Vector or Fluent Bit. Reading the
API instead of reconfiguring the node avoids both. This is the same reasoning
`nas/kmsg-capture.sh` records for the off-box capture.

`--tail` (only messages that arrive after attach) rather than a ring-buffer
replay, for one reason: an alert keyed on `USB disconnect` would re-fire every
time the pod restarted and replayed an old disconnect. The cost is that the
messages from the seconds before this pod starts — notably a boot log — never
reach Loki. That gap is deliberate and already covered: `nas/kmsg-capture.sh`
attaches without `--tail` and keeps 14 days of full logs on the Synology. The two
captures defend different failures and neither replaces the other.

This pod also dies with the node it watches, which is why it does not replace the
NAS capture: it covers the class where the node stays up and a device goes away
(the 2026-09-13 drop), not a panic or a power cut. Panic capture would be
`netconsole`, which Talos's kernel config cannot currently bind: CONFIG_NETCONSOLE
is built in and binds during kernel init, but every NIC driver is a module loaded
afterwards, and CONFIG_NETCONSOLE_DYNAMIC is unset.

The credential is an `os:reader` talosconfig (the narrowest role that can read
dmesg — no shutdown, no config write), delivered by the ExternalSecret emitted
here from SSM `/k8s/kmsg/talosconfig`, reaching the Talos API at <node>:50000.
Mounted OPTIONALLY so a deploy into an environment with an unseeded parameter
still schedules; the container then exits on the missing file and backs off,
which reads clearly in `kubectl logs`.
"""

from __future__ import annotations

import imports.k8s as k8s
from constructs import Construct

from adanalife_k8s import eso
from adanalife_k8s.constructs.talosctl import (
    FETCH_TALOSCTL,
    TALOS_NODE,
    TALOSCONFIG_PATH,
    TALOSCTL_PATH,
    TALOSCTL_URL,
)
from adanalife_k8s.naming import (
    CONFIG_HASH_ANNOTATION,
    config_hash,
    meta_labels,
    selector,
)

NAME = "kmsg"
NAMESPACE = "kmsg"
# python:3.14-alpine — matches constructs/ups_monitor.py, so the node's image
# cache is already warm and this adds no new supply-chain surface. Nothing here
# is Python; the image is a base for the fetched binary and its initContainer.
IMAGE = "python:3.14-alpine"
# The os:reader-scoped talosconfig, delivered by the ExternalSecret emitted in
# KmsgShipper (cluster store → SSM /k8s/kmsg/talosconfig).
TALOSCONFIG_SECRET = "kmsg-talosconfig"

# Reattach on any exit instead of letting the container die: a stream the API
# closes reconnects after a short pause, and an absent talosconfig (the Secret
# is optional, so an unseeded env still schedules) waits rather than crashes.
# Both stay visible in the pod log; neither shows up as a restart.
_RUN_SCRIPT = f"""\
while :; do
  if [ ! -s {TALOSCONFIG_PATH} ]; then
    echo "kmsg: {TALOSCONFIG_PATH} is absent or empty; waiting for the Secret" >&2
    sleep 60
    continue
  fi
  {TALOSCTL_PATH} --talosconfig {TALOSCONFIG_PATH} --nodes {TALOS_NODE} dmesg --follow --tail
  echo "kmsg: talosctl exited $?; reattaching" >&2
  sleep 5
done
"""


class KmsgShipper(Construct):
    """The kernel-log shipper + its initContainer ConfigMap. Cluster-singleton
    (one minipc) in its own `kmsg` namespace — env-agnostic, authored once and
    delivered by a dedicated minipc-only Argo Application (see
    constructs/argocd.py). See the module docstring for why it reads the API
    rather than configuring KmsgLogConfig, and why it uses `--tail`."""

    def __init__(self, scope: Construct, id: str = NAME):
        super().__init__(scope, id)
        labels = meta_labels(NAME, part_of="infra")
        sel = selector(NAME)

        scripts = {"fetch-talosctl.py": FETCH_TALOSCTL}
        k8s.KubeConfigMap(
            self,
            "fetch",
            metadata=k8s.ObjectMeta(name=NAME, namespace=NAMESPACE, labels=labels),
            data=scripts,
        )

        # Cluster store (not a namespaced SecretStore): the kmsg namespace has no
        # eso-aws-credentials of its own, and one parameter doesn't justify
        # bootstrapping one. Same call the UPS monitor makes.
        eso.external_secret(
            self,
            "talosconfig-secret",
            name=TALOSCONFIG_SECRET,
            namespace=NAMESPACE,
            store=("aws-parameterstore-cluster", "ClusterSecretStore"),
            labels=labels,
            data=[eso.ESData(secret_key="talosconfig", key="/k8s/kmsg/talosconfig")],
        )

        # Shared security floor for both containers: non-root, no privilege, no
        # writable rootfs, all caps dropped. The pod can do exactly one thing —
        # stream the kernel log off the Talos API with a read-only role.
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
            # The whole workload: stream kmsg to stdout and let alloy-logs do the
            # rest. The loop is what keeps the restart count meaningful: the
            # Talos API drops the stream every ~12h, and the credential mount is
            # optional, so without it every drop and every unseeded environment
            # reads as a crashloop. `--tail` means each reattach resumes without
            # replaying the ring.
            command=["sh", "-c", _RUN_SCRIPT],
            env=[k8s.EnvVar(name="HOME", value="/tmp")],
            security_context=secctx,
            resources=k8s.ResourceRequirements(
                requests={
                    "cpu": k8s.Quantity.from_string("10m"),
                    "memory": k8s.Quantity.from_string("32Mi"),
                },
                # Headroom for talosctl, a ~50MB Go binary.
                limits={"memory": k8s.Quantity.from_string("128Mi")},
            ),
            volume_mounts=[
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
                # Singleton — two attached streams would double every line in Loki.
                strategy=k8s.DeploymentStrategy(type="Recreate"),
                selector=k8s.LabelSelector(match_labels=sel),
                template=k8s.PodTemplateSpec(
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
                            # OPTIONAL: absent until the SSM parameter is seeded,
                            # so the unit deploys into a fresh environment.
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
