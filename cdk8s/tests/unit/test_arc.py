"""Actions Runner Controller (ARC) tests.

Two surfaces: the supporting deploy unit (namespaces + runner LimitRange +
GitHub App ExternalSecret) and the Argo delivery of the unit (minipc-only
singleton, manual sync). The two ARC Helm releases themselves are ordinary
platform components covered by the platform-argo golden (helm_platform.py).
"""

from cdk8s import Testing as K8sTesting

from adanalife_k8s.charts import ArcChart, ArgoCDChart
from adanalife_k8s.helm_platform import cluster_components
from adanalife_k8s.config import load_env

# The console's read-only grant on the scale sets (Role + RoleBinding share the
# name).
CONSOLE_ROLE = "tripbot-console-arc"

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
    # while still capping per-container CPU/memory to protect the co-tenant
    # prod streams.
    objs = _synth(ArcChart)
    assert not _by_kind(objs, "ResourceQuota")  # the quota was the bug — gone
    lr = next(iter(_by_kind(objs, "LimitRange")))
    assert lr["metadata"]["namespace"] == "arc-runners"
    item = lr["spec"]["limits"][0]
    assert item["type"] == "Container"
    assert item["default"]["cpu"] and item["default"]["memory"]
    assert item["defaultRequest"]["cpu"] and item["defaultRequest"]["memory"]
    # dind is a native sidecar the chart injects with no resources, so these two
    # numbers ARE its budget and the request is what the scheduler packs
    # against. A token request here lets the scheduler place runners the node
    # can't feed, which is how the node died twice on 2026-08-23 — pin both so a
    # regression to a smaller default is a test failure and not an outage.
    assert item["defaultRequest"]["memory"] == "2Gi"
    assert item["default"]["memory"] == "3Gi"


def test_arc_github_app_secret_reads_the_cluster_store():
    objs = _synth(ArcChart)
    es = next(iter(_by_kind(objs, "ExternalSecret")))
    assert es["metadata"]["name"] == "arc-github-app"
    assert es["metadata"]["namespace"] == "arc-runners"
    # platform components read the cluster-scoped store (no per-ns creds bootstrap)
    assert es["spec"]["secretStoreRef"]["kind"] == "ClusterSecretStore"
    assert es["spec"]["secretStoreRef"]["name"] == "aws-parameterstore-cluster"
    assert es["spec"]["dataFrom"][0]["extract"]["key"] == "/k8s/arc/github-app"


def test_console_reads_the_scale_sets_and_nothing_else():
    # The console's runner panel reads the scale sets to report CI capacity. It
    # must stay read-only and must not reach the runner pods or the GitHub App
    # credential sharing this namespace — the panel has no button, and this is
    # the grant that guarantees it can't grow one.
    objs = _synth(ArcChart)
    role = next(
        r for r in _by_kind(objs, "Role") if r["metadata"]["name"] == CONSOLE_ROLE
    )
    assert role["metadata"]["namespace"] == "arc-runners"
    for rule in role["rules"]:
        assert rule["apiGroups"] == ["actions.github.com"]
        assert rule["resources"] == ["autoscalingrunnersets"]
        assert set(rule["verbs"]) <= {"get", "list", "watch"}
    binding = next(
        rb
        for rb in _by_kind(objs, "RoleBinding")
        if rb["metadata"]["name"] == CONSOLE_ROLE
    )
    assert binding["roleRef"]["name"] == CONSOLE_ROLE
    # Subjects are the consoles' ServiceAccounts in their own env namespaces —
    # the cross-namespace hop the console's own AppProject can't grant itself.
    assert {(s["name"], s["namespace"]) for s in binding["subjects"]} == {
        ("tripbot-console", env) for env in ("prod-1", "stage-1")
    }


# --- the platform components (the two OCI Helm releases) ---


def test_minipc_platform_carries_both_arc_releases():
    comps = {c.release: c for c in cluster_components("minipc", load_env("prod-1"))}
    controller = comps["arc-controller"]
    assert controller.chart == "gha-runner-scale-set-controller"
    assert controller.namespace == "arc-systems"
    runners = comps["arc-amd64"]
    assert runners.chart == "gha-runner-scale-set"
    assert runners.namespace == "arc-runners"
    assert runners.value_files == ("arc/runners/values.yml",)


def test_k3d_platform_has_no_arc():
    releases = {c.release for c in cluster_components("k3d", load_env("development"))}
    assert not {r for r in releases if r.startswith("arc-")}


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
