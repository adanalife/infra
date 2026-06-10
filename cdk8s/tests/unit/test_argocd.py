"""The Argo CD config is parameterized by env-set so one authoring path emits both
the minipc instance (prod-1 + stage-1, tailscale UI) and a SEPARATE k3d dev-cluster
instance (development only, no UI). Each Argo runs in its own cluster and targets
in-cluster — no cross-cluster wiring. These pin that the dev variant is scoped to
development and the data unit never prunes on either.
"""

from cdk8s import Testing as K8sTesting

from adanalife_k8s.charts import ArgoCDChart

_DEV = dict(envs=("development",), autosync_envs=("development",), ui_ingress=False)


def _synth(**kwargs):
    app = K8sTesting.app()
    chart = ArgoCDChart(app, "argocd", **kwargs)
    return K8sTesting.synth(chart)


def _appset(objs, name):
    return next(
        o
        for o in objs
        if o["kind"] == "ApplicationSet" and o["metadata"]["name"] == name
    )


def test_minipc_default_has_tailscale_ui_and_both_envs():
    objs = _synth()
    assert any(o["kind"] == "Ingress" for o in objs)  # tailscale UI
    envs = {
        e["env"]
        for e in _appset(objs, "tripbot-apps")["spec"]["generators"][0]["list"][
            "elements"
        ]
    }
    assert envs == {"prod-1", "stage-1"}


def test_dev_is_development_only_no_ui():
    objs = _synth(**_DEV)
    assert not any(
        o["kind"] == "Ingress" for o in objs
    )  # no tailnet UI on the dev cluster
    proj = next(o for o in objs if o["kind"] == "AppProject")
    assert {d["namespace"] for d in proj["spec"]["destinations"]} == {"development"}
    # development apps autosync (it's throwaway)
    assert "development" in _appset(objs, "tripbot-apps")["spec"]["templatePatch"]


def test_data_appset_never_prunes_either_variant():
    for kwargs in ({}, _DEV):
        data = _appset(_synth(**kwargs), "tripbot-data")
        opts = data["spec"]["template"]["spec"]["syncPolicy"]["syncOptions"]
        assert "Prune=false" in opts
