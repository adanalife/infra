"""Actions Runner Controller (ARC) tests.

Two surfaces: the supporting deploy unit (namespaces + runner LimitRange +
GitHub App ExternalSecret) and the Argo delivery of the unit (minipc-only
singleton, manual sync). The two ARC Helm releases themselves are ordinary
platform components covered by the platform-argo golden (helm_platform.py).
"""

from pathlib import Path

import yaml
from cdk8s import Testing as K8sTesting

from adanalife_k8s.charts import ArcChart, ArgoCDChart
from adanalife_k8s.constructs.arc import WORK_REAP_AGE_MINUTES, WORK_ROOT
from adanalife_k8s.helm_platform import cluster_components
from adanalife_k8s.config import load_env

# The console's read-only grant on the scale sets (Role + RoleBinding share the
# name).
CONSOLE_ROLE = "tripbot-console-arc"

_DEV = dict(cluster="k3d")


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


def test_arc_runners_namespace_is_privileged_for_hostpath():
    # Runner pods mount hostPath caches and workspaces, which the cluster-wide
    # baseline PodSecurity rejects without this exemption. The controller ns
    # stays unlabeled.
    ns = {
        n["metadata"]["name"]: n for n in _synth(ArcChart) if n["kind"] == "Namespace"
    }
    assert (
        ns["arc-runners"]["metadata"]["labels"]["pod-security.kubernetes.io/enforce"]
        == "privileged"
    )
    assert "labels" not in ns["arc-systems"]["metadata"]


def test_arc_work_volume_is_per_pod_hostpath():
    # The job workspace is a hostPath carved per pod by subPathExpr, NOT a
    # generic ephemeral volume: a PVC cannot exist before the pod is
    # scheduled, and local-path cannot bind Immediate (it learns the node from
    # the scheduled pod), so an ephemeral volume deadlocks the scheduler and
    # costs a random 4-73s per job. See infra#1194/#1195.
    values = yaml.safe_load(
        (Path(__file__).parents[3] / "k8s/arc/runners/values.yml").read_text()
    )
    spec = values["template"]["spec"]
    work = next(v for v in spec["volumes"] if v["name"] == "work")
    assert "ephemeral" not in work, "an ephemeral volume re-introduces the deadlock"
    assert work["hostPath"]["path"] == WORK_ROOT

    # Both mounts must carve per pod, or two concurrent runners share a _work
    # directory -- which is exactly what maxRunners > 1 makes possible.
    mounts = [
        m
        for c in spec["containers"] + spec["initContainers"]
        for m in c["volumeMounts"]
        if m["name"] == "work"
    ]
    assert len(mounts) == 2
    assert all(m.get("subPathExpr") == "$(POD_NAME)" for m in mounts)

    # subPathExpr interpolates from the container's own env, so a container
    # mounting work without POD_NAME would get a literal "$(POD_NAME)" dir.
    for c in spec["containers"] + spec["initContainers"]:
        if not any(m["name"] == "work" for m in c["volumeMounts"]):
            continue
        env = {e["name"]: e for e in c["env"]}
        assert env["POD_NAME"]["valueFrom"]["fieldRef"]["fieldPath"] == "metadata.name"


def test_arc_workspace_reaper_cannot_eat_a_live_job():
    # A subPath directory outlives its pod (verified on the node), so the
    # cleanup a Delete-reclaim PVC used to do is now this CronJob's.
    objs = _synth(ArcChart)
    cj = next(iter(_by_kind(objs, "CronJob")))
    assert cj["metadata"]["name"] == "arc-workspace-reap"
    assert cj["spec"]["concurrencyPolicy"] == "Forbid"  # two copies would race

    pod = cj["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    script = pod["containers"][0]["command"][-1]

    # Four times the 30-minute timeout every fleet workflow sets: a running
    # job's workspace must never match.
    assert f"-mmin +{WORK_REAP_AGE_MINUTES}" in script
    assert WORK_REAP_AGE_MINUTES >= 120

    # Without -mindepth 1, find matches WORK_ROOT itself and rm -rf takes the
    # mount point with every live workspace under it.
    assert "-mindepth 1" in script
    assert "-maxdepth 1" in script

    # It must only ever reap inside the workspace root.
    assert script.count(WORK_ROOT) == 1
    assert script.strip().startswith(f"find {WORK_ROOT} ")


def test_arc_runner_limitrange_bounds_containers():
    # A LimitRange (not a ResourceQuota) so a container that declares no
    # resources gets defaults instead of being quota-rejected.
    objs = _synth(ArcChart)
    assert not _by_kind(objs, "ResourceQuota")
    lr = next(iter(_by_kind(objs, "LimitRange")))
    assert lr["metadata"]["namespace"] == "arc-runners"
    item = lr["spec"]["limits"][0]
    assert item["type"] == "Container"
    assert item["default"]["cpu"] and item["default"]["memory"]
    assert item["defaultRequest"]["cpu"] and item["defaultRequest"]["memory"]
    # The only container these reach is the chown-caches init
    # container. Keep them small: a build-sized default would hand any
    # container added without resources a budget nobody sized for it.
    assert item["defaultRequest"]["memory"] == "32Mi"
    assert item["default"]["memory"] == "128Mi"


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
