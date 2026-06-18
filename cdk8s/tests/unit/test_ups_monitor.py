"""UPS monitor tests.

The load-bearing assertion is the OBSERVE-ONLY invariant: this stage must have no
path to a node reboot (the prod DB is still on an ephemeral local-path volume, so
an auto-shutdown now would cause the very data loss it's meant to prevent). So the
container must be a pure network reader — no `talosctl`/shutdown in its command,
no privilege, no host namespaces, no writable rootfs. The Argo tests pin that the
singleton Application is minipc-only and MANUAL-sync (arming is a deliberate flip,
never auto-deployed).
"""

from cdk8s import Chart
from cdk8s import Testing as K8sTesting

from adanalife_k8s.charts import ArgoCDChart
from adanalife_k8s.constructs.ups_monitor import IMAGE, UpsMonitor

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
)


def _synth():
    app = K8sTesting.app()
    chart = Chart(app, "t")
    UpsMonitor(chart)
    return K8sTesting.synth(chart)


def _deploy(objs):
    return next(
        o
        for o in objs
        if o["kind"] == "Deployment" and o["metadata"]["name"] == "ups-monitor"
    )


# --- the observe-only guard: no path from this pod to a node reboot ---


def test_command_is_read_only_and_has_no_shutdown_path():
    container = _deploy(_synth())["spec"]["template"]["spec"]["containers"][0]
    script = "".join(container["args"])
    assert "upsc" in script  # it reads status...
    # ...and there is NO way to act on that status. If arming (stage 2) ever lands
    # here instead of behind the storage gate, this fails loudly.
    assert "talosctl" not in script
    assert "shutdown" not in script.lower()


def test_security_context_forbids_privilege_and_host_access():
    deploy = _deploy(_synth())
    pod = deploy["spec"]["template"]["spec"]
    sc = pod["containers"][0]["securityContext"]
    assert sc["allowPrivilegeEscalation"] is False
    assert sc["runAsNonRoot"] is True
    assert sc["readOnlyRootFilesystem"] is True
    assert sc["capabilities"]["drop"] == ["ALL"]
    assert sc.get("privileged") in (None, False)
    # no host namespaces (the awushensky/nut-client footgun we explicitly avoided)
    assert pod.get("hostPid") in (None, False)
    assert pod.get("hostNetwork") in (None, False)


def test_singleton_shape():
    deploy = _deploy(_synth())
    assert deploy["metadata"]["namespace"] == "ups"
    assert deploy["spec"]["replicas"] == 1
    assert deploy["spec"]["strategy"]["type"] == "Recreate"
    assert deploy["spec"]["template"]["spec"]["containers"][0]["image"] == IMAGE


# --- Argo delivery: minipc-only singleton, manual sync ---


def _argo(**kwargs):
    app = K8sTesting.app()
    return K8sTesting.synth(ArgoCDChart(app, "argocd", **kwargs))


def _appset(objs, name):
    return next(
        o
        for o in objs
        if o["kind"] == "ApplicationSet" and o["metadata"]["name"] == name
    )


def test_minipc_emits_ups_monitor_application_manual_sync():
    objs = _argo()  # minipc defaults (ups_monitor=True)
    appset = _appset(objs, "ups-monitor")
    spec = appset["spec"]["template"]["spec"]
    assert spec["project"] == "infra"
    assert spec["source"]["directory"]["include"] == "ups-monitor.k8s.yaml"
    assert spec["destination"]["namespace"] == "ups"
    assert "CreateNamespace=true" in spec["syncPolicy"]["syncOptions"]
    # MANUAL sync: no `automated` block (arming is a deliberate hand sync)
    assert "automated" not in spec["syncPolicy"]
    assert "templatePatch" not in appset["spec"]
    # the infra project must permit the `ups` destination
    infra = next(
        o
        for o in objs
        if o["kind"] == "AppProject" and o["metadata"]["name"] == "infra"
    )
    assert "ups" in {d["namespace"] for d in infra["spec"]["destinations"]}
    # CreateNamespace=true creates the `ups` Namespace as a PreSync resource, so
    # the project must permit it — the omission that failed the first sync (#761).
    assert "Namespace" in {c["kind"] for c in infra["spec"]["clusterResourceWhitelist"]}


def test_dev_omits_ups_monitor():
    objs = _argo(**_DEV)
    assert not [
        o
        for o in objs
        if o["kind"] == "ApplicationSet" and o["metadata"]["name"] == "ups-monitor"
    ]
    infra = next(
        o
        for o in objs
        if o["kind"] == "AppProject" and o["metadata"]["name"] == "infra"
    )
    assert "ups" not in {d["namespace"] for d in infra["spec"]["destinations"]}
    assert "Namespace" not in {
        c["kind"] for c in infra["spec"]["clusterResourceWhitelist"]
    }
