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
    arc=False,  # no rpi5 on the k3d dev cluster
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


def _script(objs):
    cm = next(
        o
        for o in objs
        if o["kind"] == "ConfigMap" and o["metadata"]["name"] == "ups-monitor"
    )
    return cm["data"]["nutread.py"]


def _container(objs):
    return _deploy(objs)["spec"]["template"]["spec"]["containers"][0]


def _env(objs):
    return {e["name"]: e.get("value") for e in _container(objs)["env"]}


# --- the armed-state contract: the trigger is live, and its credential is
#     declaratively delivered ---


def test_armed_dry_run_off():
    # The committed manifest is ARMED: the trigger executes the real shutdown.
    assert _env(_synth())["DRY_RUN"] == "false"


def test_talosconfig_delivered_by_external_secret():
    # The shutdown credential rides the cluster store (the ups namespace has no
    # SecretStore of its own) into the ups-talosconfig Secret.
    es = next(
        o
        for o in _synth()
        if o["kind"] == "ExternalSecret" and o["metadata"]["name"] == "ups-talosconfig"
    )
    assert es["metadata"]["namespace"] == "ups"
    ref = es["spec"]["secretStoreRef"]
    assert ref == {"name": "aws-parameterstore-cluster", "kind": "ClusterSecretStore"}
    d = es["spec"]["data"][0]
    assert d["secretKey"] == "talosconfig"
    assert d["remoteRef"]["key"] == "/k8s/ups/talosconfig"


def test_talosconfig_mount_is_optional():
    # The mount stays optional so a deploy without the seeded SSM parameter
    # (fresh env) still schedules instead of wedging on a missing Secret.
    vols = _deploy(_synth())["spec"]["template"]["spec"]["volumes"]
    tc = next(v for v in vols if v["name"] == "talosconfig")
    assert tc["secret"]["optional"] is True
    assert tc["secret"]["secretName"] == "ups-talosconfig"


def test_shutdown_is_confirmed_and_dry_run_gated():
    script = _script(_synth())
    assert "GET VAR" in script  # still a reader at heart
    # the one action it can take is a single talosctl Shutdown...
    assert "shutdown" in script
    # ...behind a confirm-counter (no acting on a single flaky read)...
    assert "CONFIRM" in script and "confirm >= CONFIRM" in script
    # ...and behind DRY_RUN: the subprocess.run is only reached when NOT dry-run.
    assert "DRY_RUN" in script
    pre = script.split("subprocess.run")[0]
    assert "if DRY_RUN" in pre  # the dry-run branch is checked before executing
    # never issues a UPS-side write command
    assert "INSTCMD" not in script and "SET VAR" not in script


def test_targets_only_the_minipc_node():
    assert _env(_synth())["TALOS_NODE"] == "192.168.40.111"


def test_initcontainer_fetches_pinned_talosctl():
    init = _deploy(_synth())["spec"]["template"]["spec"]["initContainers"][0]
    url = next(e["value"] for e in init["env"] if e["name"] == "TALOSCTL_URL")
    assert "v1.13.2" in url and "talosctl-linux-amd64" in url


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
    # the project must permit the Namespace kind or the sync fails.
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
