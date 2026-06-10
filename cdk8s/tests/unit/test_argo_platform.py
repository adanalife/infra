"""Argo-native platform delivery: each platform Helm release becomes a multi-source
Argo Application (upstream chart + in-repo values via a `$values` ref). The
bootstrap floor Argo can't own — cilium (the CNI) + argo-cd (itself) — must never
get an Application. See constructs/argo_platform.py.
"""

from cdk8s import Testing as K8sTesting

from adanalife_k8s.charts import PlatformArgoChart


def _synth():
    app = K8sTesting.app()
    chart = PlatformArgoChart(app, "platform-argo")
    return K8sTesting.synth(chart)


def _apps(objs):
    return [o for o in objs if o["kind"] == "Application"]


def _release(app):
    return app["spec"]["sources"][0]["helm"]["releaseName"]


def test_bootstrap_floor_excluded():
    releases = {_release(a) for a in _apps(_synth())}
    # cilium = the CNI Argo rides on; argocd = Argo's own install
    assert "cilium" not in releases
    assert "argocd" not in releases
    # the safe middle is present
    assert {"external-secrets", "traefik", "cert-manager"} <= releases


def test_every_app_is_multisource_pinned_with_values_ref():
    for a in _apps(_synth()):
        sources = a["spec"]["sources"]
        assert len(sources) == 2
        chart_src, values_src = sources
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


def test_per_env_apps_name_qualified():
    names = {a["metadata"]["name"] for a in _apps(_synth())}
    # external-dns + NATS exist once per env, name-qualified so they don't collide
    assert {
        "prod-1-nats",
        "stage-1-nats",
        "prod-1-external-dns",
        "stage-1-external-dns",
    } <= names
