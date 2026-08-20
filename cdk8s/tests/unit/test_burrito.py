"""Burrito is a plan/drift-detect trial: no layer may auto-apply (applies stay
Dana-driven), the runner credential comes from the read-only ExternalSecret,
and the OCI chart registry the platform Application pulls from must be
registered with Argo. See constructs/burrito.py.
"""

from cdk8s import Testing as K8sTesting

from adanalife_k8s.charts import BurritoChart, PlatformArgoChart


def _synth():
    app = K8sTesting.app()
    chart = BurritoChart(app, "burrito")
    return K8sTesting.synth(chart)


def _platform_synth():
    app = K8sTesting.app()
    chart = PlatformArgoChart(app, "platform-argo")
    return K8sTesting.synth(chart)


def _kind(objs, kind):
    return [o for o in objs if o["kind"] == kind]


def test_layers_never_auto_apply():
    objs = _synth()
    layers = _kind(objs, "TerraformLayer")
    assert layers  # the trial ships at least the core layer
    for layer in layers:
        assert layer["spec"]["remediationStrategy"]["autoApply"] is False
    # the repository must not flip the default on for its layers either
    for repo in _kind(objs, "TerraformRepository"):
        assert not repo["spec"].get("remediationStrategy", {}).get("autoApply")


def test_runner_creds_come_from_the_external_secret():
    objs = _synth()
    secret_names = {
        es["spec"]["target"]["name"] for es in _kind(objs, "ExternalSecret")
    }
    for layer in _kind(objs, "TerraformLayer"):
        for ref in layer["spec"]["overrideRunnerSpec"]["envFrom"]:
            assert ref["secretRef"]["name"] in secret_names


def test_oci_chart_registry_is_registered():
    objs = _platform_synth()
    (burrito_app,) = [
        o
        for o in _kind(objs, "Application")
        if o["spec"]["sources"][0].get("chart") == "burrito"
    ]
    repo_url = burrito_app["spec"]["sources"][0]["repoURL"]
    assert "://" not in repo_url  # Argo's OCI repoURL form is scheme-less
    registered = {
        o["stringData"]["url"]
        for o in _kind(objs, "Secret")
        if o["metadata"]["labels"].get("argocd.argoproj.io/secret-type") == "repository"
        and o["stringData"].get("enableOCI") == "true"
    }
    assert repo_url in registered
