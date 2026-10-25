"""Argo-native platform delivery: each platform Helm release becomes a multi-source
Argo Application (upstream chart + in-repo values via a `$values` ref). The
bootstrap floor Argo can't own — cilium (the CNI) + argo-cd (itself) — must never
get an Application. See constructs/argo_platform.py.
"""

from pathlib import Path

import yaml
from cdk8s import Testing as K8sTesting

from adanalife_k8s.charts import PlatformArgoChart


def _synth():
    app = K8sTesting.app()
    chart = PlatformArgoChart(app, "platform-argo")
    return K8sTesting.synth(chart)


def _apps(objs):
    """The Helm Applications (multi-source); the gitops root has one plain source."""
    return [o for o in objs if o["kind"] == "Application" and "sources" in o["spec"]]


def _root(objs, name="gitops"):
    (app,) = [
        o for o in objs if o["kind"] == "Application" and o["metadata"]["name"] == name
    ]
    return app


def _release(app):
    return app["spec"]["sources"][0]["helm"]["releaseName"]


def test_non_argo_manageable_charts_excluded():
    releases = {_release(a) for a in _apps(_synth())}
    # cilium = the CNI Argo rides on; argocd = Argo's own install (bootstrap floor)
    assert "cilium" not in releases
    assert "argocd" not in releases
    # traefik + external-dns are host-IP-coupled (node InternalIP in gitignored
    # values.local.yml) — not git-declarable, so they stay task-installed.
    assert "traefik" not in releases
    assert "external-dns" not in releases
    assert "external-dns-stage" not in releases
    # the git-declarable middle is present
    assert {
        "external-secrets",
        "cert-manager",
        "cnpg",
        "plugin-barman-cloud",
        "k8s-monitoring",
        "nats",
    } <= releases


def test_every_app_is_multisource_pinned_with_values_ref():
    for a in _apps(_synth()):
        chart_src, values_src = a["spec"]["sources"][:2]
        assert chart_src["chart"]
        assert chart_src["targetRevision"]  # version-pinned, never floating
        assert values_src["ref"] == "values"  # the in-repo $values source
        for vf in chart_src["helm"].get("valueFiles", []):
            assert vf.startswith("$values/k8s/")


def test_single_broad_platform_project():
    projects = [o for o in _synth() if o["kind"] == "AppProject"]
    assert len(projects) == 1
    proj = projects[0]
    assert proj["metadata"]["name"] == "platform"
    # broad on purpose (platform installs CRDs/ClusterRoles); distinct from the
    # restrictive tripbot app project.
    assert {"group": "*", "kind": "*"} in proj["spec"]["clusterResourceWhitelist"]


def test_gitops_root_tracks_exactly_the_argo_config():
    app = _root(_synth())
    assert app["metadata"]["namespace"] == "argocd"
    assert app["spec"]["project"] == "platform"
    src = app["spec"]["source"]
    assert src["path"] == "cdk8s/dist"
    # Only the files `task gitops:apply` applies — never the app units, which
    # their own Applications deliver, nor the k3d dev cluster's Argo config.
    assert src["directory"] == {"include": "{argocd.k8s.yaml,platform-argo.k8s.yaml}"}
    taskfile = (Path(__file__).resolve().parents[3] / "Taskfile.yml").read_text()
    (line,) = [
        row
        for row in taskfile.splitlines()
        if row.strip().startswith("GITOPS_MANIFESTS:")
    ]
    assert line.split(":", 1)[1].split() == [
        "cdk8s/dist/argocd.k8s.yaml",
        "cdk8s/dist/platform-argo.k8s.yaml",
    ]


def test_gitops_root_is_manual_and_never_prunes():
    # A sync must never delete: a synth bug dropping an ApplicationSet would
    # cascade into the prod Applications it generates. Removal is gitops:prune.
    policy = _root(_synth())["spec"]["syncPolicy"]
    assert "automated" not in policy
    assert "Prune=false" in policy["syncOptions"]


def test_nfs_pv_app_watches_both_envs_pvs_and_never_prunes():
    app = _root(_synth(), "nfs-pv")
    assert app["spec"]["source"]["directory"] == {
        "include": "{prod-1-nfs-pv.k8s.yaml,stage-1-nfs-pv.k8s.yaml}"
    }
    for env in ("prod-1", "stage-1"):
        assert (
            Path(__file__).resolve().parents[2] / f"dist/{env}-nfs-pv.k8s.yaml"
        ).exists()
    policy = app["spec"]["syncPolicy"]
    assert "automated" not in policy
    assert "Prune=false" in policy["syncOptions"]
    # A sync must not write the committed placeholder NFS coords over the live ones.
    assert "RespectIgnoreDifferences=true" in policy["syncOptions"]
    (ignore,) = app["spec"]["ignoreDifferences"]
    assert ignore["kind"] == "PersistentVolume"
    assert {"/spec/nfs/server", "/spec/nfs/path", "/spec/claimRef"} <= set(
        ignore["jsonPointers"]
    )


def test_per_env_apps_name_qualified():
    names = {a["metadata"]["name"] for a in _apps(_synth())}
    # NATS exists once per env, name-qualified so prod/stage don't collide.
    # (external-dns is excluded — host-coupled — so it's not here.)
    assert {"prod-1-nats", "stage-1-nats"} <= names
    assert not any(n.endswith("-external-dns") for n in names)


def test_tailscale_operator_delivers_the_ingress_proxygroup():
    (app,) = [a for a in _apps(_synth()) if _release(a) == "tailscale-operator"]
    # third source: the in-repo ProxyGroup, scoped so the chart's values file
    # isn't picked up as a manifest.
    raw = app["spec"]["sources"][2]
    assert raw["path"] == "k8s/tailscale-operator"
    assert raw["directory"] == {"include": "proxygroup.yml"}


def test_kyverno_delivers_its_policies():
    (app,) = [a for a in _apps(_synth()) if _release(a) == "kyverno"]
    raw = app["spec"]["sources"][2]
    assert raw["path"] == "k8s/kyverno"
    assert raw["directory"] == {"include": "policies.yml"}


def test_argo_workflows_delivers_the_console_grant():
    (app,) = [a for a in _apps(_synth()) if _release(a) == "argo-workflows"]
    raw = app["spec"]["sources"][2]
    assert raw["path"] == "k8s/argo-workflows"
    assert raw["directory"] == {"include": "console-rbac.yml"}


def _console_rbac() -> dict[tuple[str, str], dict]:
    path = Path(__file__).resolve().parents[3] / "k8s/argo-workflows/console-rbac.yml"
    return {
        (d["kind"], d["metadata"]["name"]): d
        for d in yaml.safe_load_all(path.read_text())
        if d
    }


def test_console_workflows_grant_is_read_only_in_stage_1():
    docs = _console_rbac()
    role = docs[("Role", "tripbot-console-workflows")]
    binding = docs[("RoleBinding", "tripbot-console-workflows")]
    assert role["metadata"] == {
        "name": "tripbot-console-workflows",
        "namespace": "stage-1",
    }
    assert role["rules"] == [
        {
            "apiGroups": ["argoproj.io"],
            "resources": ["workflows", "workflowtemplates", "cronworkflows"],
            "verbs": ["get", "list", "watch"],
        }
    ]
    assert binding["metadata"] == role["metadata"]
    assert binding["roleRef"]["name"] == "tripbot-console-workflows"
    assert {(s["name"], s["namespace"]) for s in binding["subjects"]} == {
        ("tripbot-console", "prod-1"),
        ("tripbot-console", "stage-1"),
    }


def test_only_the_stage_console_may_submit_a_workflow():
    # The re-run button: create on workflows and nothing else, and never for
    # the prod console — it cannot start work on the cluster.
    docs = _console_rbac()
    role = docs[("Role", "tripbot-console-workflows-submit")]
    binding = docs[("RoleBinding", "tripbot-console-workflows-submit")]
    assert role["metadata"]["namespace"] == "stage-1"
    assert role["rules"] == [
        {"apiGroups": ["argoproj.io"], "resources": ["workflows"], "verbs": ["create"]}
    ]
    assert binding["roleRef"]["name"] == "tripbot-console-workflows-submit"
    assert [(s["name"], s["namespace"]) for s in binding["subjects"]] == [
        ("tripbot-console", "stage-1")
    ]
    # Nothing grants the prod console a write verb on any workflows resource.
    for (kind, _), doc in docs.items():
        if kind != "Role":
            continue
        for rule in doc["rules"]:
            if "create" in rule["verbs"]:
                assert doc["metadata"]["name"] == "tripbot-console-workflows-submit"


def test_kyverno_policies_audit_only_and_fail_open():
    # Moving a policy to Deny is a deliberate per-policy change once its
    # PolicyReports read clean; this makes that change show up here too. A
    # policy that fails closed would let a Kyverno outage block admission on
    # the single node.
    path = Path(__file__).resolve().parents[3] / "k8s/kyverno/policies.yml"
    policies = [d for d in yaml.safe_load_all(path.read_text()) if d]
    assert policies
    for p in policies:
        assert p["kind"] == "ValidatingPolicy", p["metadata"]["name"]
        assert p["spec"]["validationActions"] == ["Audit"], p["metadata"]["name"]
        assert p["spec"]["failurePolicy"] == "Ignore", p["metadata"]["name"]
