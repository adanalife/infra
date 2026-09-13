"""Kernel-log shipper tests.

The load-bearing assertion is `--tail`. Without it `talosctl dmesg --follow`
replays the whole ring buffer on attach, so every pod restart would re-emit an
old `USB disconnect` into Loki and re-fire the storage-loss alert off a fault
that is hours in the past. That makes it a correctness flag, not a preference,
and dropping it would be silent — the pod would look perfectly healthy.

The rest pins the shape the unit depends on: a read-only role reaching the node's
API, an optional credential so the unit deploys before the SSM parameter is
seeded, and an Argo Application that is minipc-only (k3d has no Talos API).
"""

from cdk8s import Chart
from cdk8s import Testing as K8sTesting

from adanalife_k8s.charts import ArgoCDChart
from adanalife_k8s.constructs.kmsg import KmsgShipper, TALOS_NODE


def _synth():
    app = K8sTesting.app()
    chart = Chart(app, "t")
    KmsgShipper(chart)
    return K8sTesting.synth(chart)


def _deploy(objs):
    return next(
        o for o in objs if o["kind"] == "Deployment" and o["metadata"]["name"] == "kmsg"
    )


def _container(objs):
    return _deploy(objs)["spec"]["template"]["spec"]["containers"][0]


# --- the streaming contract ---


def test_streams_new_messages_only():
    # --tail is what stops a pod restart replaying an old disconnect into a live
    # alert. See the module docstring.
    cmd = _container(_synth())["command"]
    assert "dmesg" in cmd
    assert "--follow" in cmd
    assert "--tail" in cmd


def test_reads_the_node_api():
    cmd = _container(_synth())["command"]
    assert cmd[cmd.index("--nodes") + 1] == TALOS_NODE


def test_credential_is_optional_so_an_unseeded_env_still_schedules():
    volumes = _deploy(_synth())["spec"]["template"]["spec"]["volumes"]
    talosconfig = next(v for v in volumes if v["name"] == "talosconfig")
    assert talosconfig["secret"]["optional"] is True


def test_talosconfig_comes_from_parameter_store():
    objs = _synth()
    es = next(
        o
        for o in objs
        if o["kind"] == "ExternalSecret" and o["metadata"]["name"] == "kmsg-talosconfig"
    )
    assert es["spec"]["data"][0]["remoteRef"]["key"] == "/k8s/kmsg/talosconfig"


def test_reader_cannot_write_its_own_filesystem():
    # Nothing here should ever need to write: it streams to stdout.
    sec = _container(_synth())["securityContext"]
    assert sec["readOnlyRootFilesystem"] is True
    assert sec["runAsNonRoot"] is True
    assert sec["allowPrivilegeEscalation"] is False


# --- Argo delivery: minipc-only singleton ---


def _argo(**kwargs):
    app = K8sTesting.app()
    return K8sTesting.synth(ArgoCDChart(app, "argocd", **kwargs))


def test_minipc_emits_kmsg_application():
    objs = _argo()  # minipc defaults (kmsg=True)
    appset = next(
        o
        for o in objs
        if o["kind"] == "ApplicationSet" and o["metadata"]["name"] == "kmsg"
    )
    spec = appset["spec"]["template"]["spec"]
    assert spec["project"] == "infra"
    assert spec["source"]["directory"]["include"] == "kmsg.k8s.yaml"
    assert spec["destination"]["namespace"] == "kmsg"
    assert "CreateNamespace=true" in spec["syncPolicy"]["syncOptions"]


def test_dev_omits_kmsg():
    # k3d has no Talos API to read, so the dev Argo must not carry the unit or
    # its namespace destination.
    objs = _argo(
        envs=("development",),
        autosync_envs=("development",),
        autosync_holdouts=(),
        selfheal=False,
        notifications_secret=False,
        tailscale_ui=False,
        lan_host="argocd.dev.whereisdana.today",
        lan_tls=False,
        ups_monitor=False,
        arc=False,
        kmsg=False,
    )
    assert not [
        o
        for o in objs
        if o["kind"] == "ApplicationSet" and o["metadata"]["name"] == "kmsg"
    ]
    infra = next(
        o
        for o in objs
        if o["kind"] == "AppProject" and o["metadata"]["name"] == "infra"
    )
    assert "kmsg" not in {d["namespace"] for d in infra["spec"]["destinations"]}
