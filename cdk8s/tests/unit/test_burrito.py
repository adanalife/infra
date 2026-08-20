"""Burrito is a plan/drift-detect trial: no layer may auto-apply (applies stay
Dana-driven), every layer's credential comes from its own read-only
ExternalSecret, GCP auth stays keyless, and the OCI chart registry the platform
Application pulls from must be registered with Argo. See constructs/burrito.py.
"""

import json
from pathlib import Path

import yaml
from cdk8s import Testing as K8sTesting

from adanalife_k8s.charts import BurritoChart, PlatformArgoChart
from adanalife_k8s.constructs.burrito import LAYERS


def _synth():
    app = K8sTesting.app()
    chart = BurritoChart(app, "burrito")
    return K8sTesting.synth(chart)


def _platform_synth():
    app = K8sTesting.app()
    chart = PlatformArgoChart(app, "platform-argo")
    return K8sTesting.synth(chart)


# The chart's own config, which carries the half of the auth setup that is
# values rather than Kubernetes objects.
VALUES = Path(__file__).parents[3] / "k8s" / "burrito" / "values.yml"


def _values():
    with VALUES.open() as f:
        return yaml.safe_load(f)


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


def test_each_layer_has_its_own_credential():
    # Sharing one credential across layers would hand every runner the
    # platform layer's grant on the automation App's private key.
    objs = _synth()
    refs = [
        ref["secretRef"]["name"]
        for layer in _kind(objs, "TerraformLayer")
        for ref in layer["spec"]["overrideRunnerSpec"]["envFrom"]
    ]
    assert len(refs) == len(set(refs))


def test_gcp_layers_authenticate_keylessly():
    # stage-1/prod-1 carry a google provider. Its credentials must be a
    # projected ServiceAccount token federated at STS — never a service
    # account key, which is what gcp-terraform-auth-model rules out.
    objs = _synth()
    configs = {
        cm["metadata"]["name"]: json.loads(cm["data"]["credential-config.json"])
        for cm in _kind(objs, "ConfigMap")
    }
    assert configs, "expected a GCP credential config for the google-provider layers"
    for config in configs.values():
        assert config["type"] == "external_account"
        assert config["credential_source"]["file"].startswith("/var/run/secrets/gcp")
        assert "burrito-plan@" in config["service_account_impersonation_url"]

    for layer in _kind(objs, "TerraformLayer"):
        spec = layer["spec"]["overrideRunnerSpec"]
        mounted = [
            v["configMap"]["name"] for v in spec.get("volumes", []) if "configMap" in v
        ]
        if not mounted:
            continue
        assert mounted[0] in configs
        (projected,) = [v for v in spec["volumes"] if "projected" in v]
        (source,) = projected["projected"]["sources"]
        assert source["serviceAccountToken"]["audience"] == "adanalife-burrito"
        assert spec["serviceAccountName"] == "burrito-runner"


def test_server_is_never_unauthenticated():
    # The chart spells this out: with both basic auth and OIDC disabled the
    # server is publicly accessible. It is a UI that can reach terraform.
    server = _values()["config"]["burrito"]["server"]
    assert server["oidc"]["enabled"] or server["basicAuth"]["enabled"]


def test_oidc_client_secret_reaches_the_server_as_its_env_var():
    # Three names have to agree or the server silently loses its OIDC secret:
    # the ExternalSecret's target, the envFrom entry in the chart values, and
    # the key, which the chart consumes as an env var and so must BE the env
    # var name.
    objs = _synth()
    (secret,) = [
        es
        for es in _kind(objs, "ExternalSecret")
        if es["spec"]["target"]["name"] == "burrito-oidc-client-secret"
    ]
    assert [d["secretKey"] for d in secret["spec"]["data"]] == [
        "BURRITO_SERVER_OIDC_CLIENTSECRET"
    ]
    assert {"secretRef": {"name": secret["spec"]["target"]["name"]}} in _values()[
        "server"
    ]["deployment"]["envFrom"]


def test_only_stage_and_prod_can_apply():
    # core holds IAM and Organizations; platform holds the automation App's
    # key. Their apply path stays a workstation gesture. And because
    # overrideRunnerSpec is per-layer rather than per-action, marking one
    # appliable would also hand its hourly drift plan an admin credential —
    # so this is a wider decision than "can I click apply".
    assert {layer.name for layer in LAYERS if layer.appliable} == {
        "stage-1",
        "prod-1",
    }


def test_credential_matches_whether_the_layer_can_apply():
    # The read-only user and the admin user are different SM parameters. A
    # layer wired to the wrong one either cannot plan or can silently write.
    objs = _synth()
    by_target = {
        es["spec"]["target"]["name"]: es for es in _kind(objs, "ExternalSecret")
    }
    for layer in LAYERS:
        secret = by_target[layer.secret_name]
        keys = [d["remoteRef"]["key"] for d in secret["spec"]["data"]]
        expected = "-apply-" if layer.appliable else "-"
        assert all(
            k.startswith(f"/k8s/burrito/{layer.sm_prefix}{expected}") for k in keys
        ), (
            layer.name,
            keys,
        )


def test_tailnet_ui_rides_the_shared_proxy_fleet():
    ing = next(
        i
        for i in _kind(_synth(), "Ingress")
        if i["spec"].get("ingressClassName") == "tailscale"
    )
    assert (
        ing["metadata"]["annotations"]["tailscale.com/proxy-group"] == "ingress-proxies"
    )
