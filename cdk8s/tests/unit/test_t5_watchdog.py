"""T5 watchdog tests.

The load-bearing assertion is that the watchdog can survive the fault it exists
to catch: it holds no hostPath, so kubelet can't strand it in
CreateContainerError the way it stranded every T5-mounting pod on 2026-09-13.
The rest pins the two reboot-loop guards (run the probe's own self-check) and the
Argo posture — minipc-only, MANUAL sync, since this unit's one action is
rebooting the node that runs prod.
"""

import subprocess
import sys

from cdk8s import Chart
from cdk8s import Testing as K8sTesting

from adanalife_k8s.charts import ArgoCDChart
from adanalife_k8s.constructs.t5_watchdog import (
    NAME,
    NAMESPACE,
    TALOSCONFIG_SSM_KEY,
    T5Watchdog,
)
from adanalife_k8s.naming import CONFIG_HASH_ANNOTATION, config_hash

_DEV = dict(
    envs=("development",),
    autosync_envs=("development",),
    autosync_holdouts=(),
    selfheal=False,
    notifications_secret=False,
    tailscale_ui=False,
    lan_host="argocd.dev.whereisdana.today",
    lan_tls=False,
    ups_monitor=False,
    t5_watchdog=False,
    arc=False,
)


def _synth():
    app = K8sTesting.app()
    chart = Chart(app, "t")
    T5Watchdog(chart)
    return K8sTesting.synth(chart)


def _by(objs, kind):
    return [o for o in objs if o["kind"] == kind]


def _deploy(objs):
    return next(o for o in _by(objs, "Deployment") if o["metadata"]["name"] == NAME)


def _pod(objs):
    return _deploy(objs)["spec"]["template"]["spec"]


def _script(objs):
    cm = next(o for o in _by(objs, "ConfigMap") if o["metadata"]["name"] == NAME)
    return cm["data"]["t5probe.py"]


def test_probe_selfcheck_passes():
    # The probe's own trigger-boundary asserts: below CONFIRM, inside the startup
    # grace, and after latching must all refuse to reboot. Runs the exact script
    # text that ships in the ConfigMap.
    r = subprocess.run(
        [sys.executable, "-c", _script(_synth()), "--selftest"],
        capture_output=True,
        text=True,
    )
    assert r.returncode == 0, r.stderr
    assert "selftest ok" in r.stdout


def test_holds_no_host_mount():
    # The whole point of probing over the Talos API: a pod with a hostPath into
    # /var/mnt would be stranded by the same fault it watches for.
    pod = _pod(_synth())
    assert not [v for v in pod["volumes"] if "hostPath" in v]
    assert not pod.get("hostNetwork") and not pod.get("hostPid")


def test_runs_unprivileged_on_a_read_only_rootfs():
    for c in _pod(_synth())["containers"] + _pod(_synth())["initContainers"]:
        sc = c["securityContext"]
        assert sc["runAsNonRoot"] and sc["readOnlyRootFilesystem"]
        assert not sc["allowPrivilegeEscalation"]
        assert sc["capabilities"]["drop"] == ["ALL"]


def test_talosconfig_is_optional_and_comes_from_the_shared_parameter():
    objs = _synth()
    vol = next(v for v in _pod(objs)["volumes"] if v["name"] == "talosconfig")
    # Optional so a cluster without the seeded parameter still schedules.
    assert vol["secret"]["optional"] is True
    es = next(o for o in _by(objs, "ExternalSecret"))
    assert es["spec"]["data"][0]["remoteRef"]["key"] == TALOSCONFIG_SSM_KEY


def test_argo_application_is_minipc_only_and_manual_sync():
    objs = K8sTesting.synth(ArgoCDChart(K8sTesting.app(), "argo"))
    appset = next(
        o for o in _by(objs, "ApplicationSet") if o["metadata"]["name"] == NAME
    )
    spec = appset["spec"]["template"]["spec"]
    assert spec["destination"]["namespace"] == NAMESPACE
    # MANUAL sync: no `automated` block — rebooting prod's node lands by hand.
    assert "automated" not in spec["syncPolicy"]
    infra = next(o for o in _by(objs, "AppProject") if o["metadata"]["name"] == "infra")
    assert NAMESPACE in {d["namespace"] for d in infra["spec"]["destinations"]}
    # CreateNamespace=true makes the Namespace a PreSync resource.
    assert "Namespace" in {c["kind"] for c in infra["spec"]["clusterResourceWhitelist"]}


def test_dev_omits_the_watchdog():
    objs = K8sTesting.synth(ArgoCDChart(K8sTesting.app(), "argo", **_DEV))
    assert not [o for o in _by(objs, "ApplicationSet") if o["metadata"]["name"] == NAME]
    infra = next(o for o in _by(objs, "AppProject") if o["metadata"]["name"] == "infra")
    assert NAMESPACE not in {d["namespace"] for d in infra["spec"]["destinations"]}


def test_pod_template_carries_the_config_digest():
    # Python reads the scripts once at startup, so a probe edit only lands if the
    # Deployment rolls.
    objs = _synth()
    cm = next(o for o in _by(objs, "ConfigMap") if o["metadata"]["name"] == NAME)
    annotations = _deploy(objs)["spec"]["template"]["metadata"]["annotations"]
    assert annotations[CONFIG_HASH_ANNOTATION] == config_hash(cm["data"])
