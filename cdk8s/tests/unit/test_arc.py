"""Actions Runner Controller (ARC) tests.

Three surfaces: the supporting deploy unit (namespaces + runner ResourceQuota +
GitHub App ExternalSecret), the platform-stack Helm Applications (the two OCI
charts), and the Argo delivery of the unit (minipc-only singleton, manual sync).
"""

from cdk8s import Testing as K8sTesting

from adanalife_k8s.charts import ArcChart, ArgoCDChart, PlatformArgoChart

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
    arc=False,
)


def _synth(chart):
    app = K8sTesting.app()
    return K8sTesting.synth(chart(app, "x"))


def _by_kind(objs, kind):
    return [o for o in objs if o["kind"] == kind]


# --- the supporting deploy unit (arc.k8s.yaml) ---


def test_arc_unit_emits_both_namespaces():
    objs = _synth(ArcChart)
    assert {n["metadata"]["name"] for n in _by_kind(objs, "Namespace")} == {
        "arc-systems",
        "arc-runners",
    }


def test_arc_runners_namespace_is_privileged_for_dind():
    # dind runs a privileged sidecar; the cluster-wide baseline PodSecurity would
    # reject it without this exemption. The controller ns stays unlabeled.
    ns = {
        n["metadata"]["name"]: n for n in _synth(ArcChart) if n["kind"] == "Namespace"
    }
    assert (
        ns["arc-runners"]["metadata"]["labels"]["pod-security.kubernetes.io/enforce"]
        == "privileged"
    )
    assert "labels" not in ns["arc-systems"]["metadata"]


def test_arc_runner_limitrange_bounds_containers():
    # A LimitRange (not a ResourceQuota) so ARC's resource-less injected dind /
    # init-dind-externals containers get defaults instead of being quota-rejected,
    # while still capping per-container CPU/memory to protect the shared rpi5.
    objs = _synth(ArcChart)
    assert not _by_kind(objs, "ResourceQuota")  # the quota was the bug — gone
    lr = next(iter(_by_kind(objs, "LimitRange")))
    assert lr["metadata"]["namespace"] == "arc-runners"
    item = lr["spec"]["limits"][0]
    assert item["type"] == "Container"
    assert item["default"]["cpu"] and item["default"]["memory"]
    assert item["defaultRequest"]["cpu"] and item["defaultRequest"]["memory"]


def test_arc_github_app_secret_reads_the_cluster_store():
    objs = _synth(ArcChart)
    es = next(iter(_by_kind(objs, "ExternalSecret")))
    assert es["metadata"]["name"] == "arc-github-app"
    assert es["metadata"]["namespace"] == "arc-runners"
    # platform components read the cluster-scoped store (no per-ns creds bootstrap)
    assert es["spec"]["secretStoreRef"]["kind"] == "ClusterSecretStore"
    assert es["spec"]["secretStoreRef"]["name"] == "aws-parameterstore-cluster"
    assert es["spec"]["dataFrom"][0]["extract"]["key"] == "/k8s/arc/github-app"


# --- the platform-stack Helm Applications (OCI charts) ---


def test_platform_emits_both_arc_charts_from_oci():
    objs = _synth(PlatformArgoChart)
    apps = {
        o["metadata"]["name"]: o
        for o in objs
        if o["kind"] == "Application" and o["metadata"]["name"].startswith("arc-")
    }
    assert set(apps) == {"arc-controller", "arc-arm64-tripbot"}
    charts = {}
    for name, app in apps.items():
        chart_src = next(s for s in app["spec"]["sources"] if s.get("chart"))
        assert (
            chart_src["repoURL"] == "ghcr.io/actions/actions-runner-controller-charts"
        )
        assert chart_src["targetRevision"] == "0.14.2"
        charts[name] = chart_src["chart"]
    assert charts["arc-controller"] == "gha-runner-scale-set-controller"
    assert charts["arc-arm64-tripbot"] == "gha-runner-scale-set"


# --- Argo delivery of the unit: minipc-only singleton, manual sync ---


def _argo(**kwargs):
    app = K8sTesting.app()
    return K8sTesting.synth(ArgoCDChart(app, "argocd", **kwargs))


def _infra_project(objs):
    return next(
        o
        for o in objs
        if o["kind"] == "AppProject" and o["metadata"]["name"] == "infra"
    )


def test_minipc_delivers_arc_unit_manual_sync():
    objs = _argo()  # minipc defaults (arc=True)
    appset = next(
        o
        for o in objs
        if o["kind"] == "ApplicationSet" and o["metadata"]["name"] == "arc"
    )
    spec = appset["spec"]["template"]["spec"]
    assert spec["project"] == "infra"
    assert spec["source"]["directory"]["include"] == "arc.k8s.yaml"
    assert spec["destination"]["namespace"] == "arc-runners"
    # MANUAL sync — the ARC Helm apps it underpins are MONITOR-ONLY too
    assert "automated" not in spec["syncPolicy"]
    # the infra project must permit both arc namespaces + the Namespace kind
    dests = {d["namespace"] for d in _infra_project(objs)["spec"]["destinations"]}
    assert {"arc-systems", "arc-runners"} <= dests
    assert "Namespace" in {
        c["kind"] for c in _infra_project(objs)["spec"]["clusterResourceWhitelist"]
    }


def test_dev_omits_arc():
    objs = _argo(**_DEV)
    assert not [
        o
        for o in objs
        if o["kind"] == "ApplicationSet" and o["metadata"]["name"] == "arc"
    ]
    dests = {d["namespace"] for d in _infra_project(objs)["spec"]["destinations"]}
    assert not ({"arc-systems", "arc-runners"} & dests)
