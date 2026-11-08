"""Gatus prober tests.

Pins what the alert rule depends on: metrics are on and scraped, every endpoint
carries conditions (an endpoint with none always passes), and the unit is
minipc-only.
"""

import yaml
from cdk8s import Chart
from cdk8s import Testing as K8sTesting

from adanalife_k8s.charts import ArgoCDChart
from adanalife_k8s.constructs.gatus import PORT, Gatus


def _synth():
    app = K8sTesting.app()
    chart = Chart(app, "t")
    Gatus(chart)
    return K8sTesting.synth(chart)


def _config(objs):
    cm = next(o for o in objs if o["kind"] == "ConfigMap")
    return yaml.safe_load(cm["data"]["config.yaml"])


def test_metrics_are_exported_and_scraped():
    objs = _synth()
    assert _config(objs)["metrics"] is True
    deploy = next(o for o in objs if o["kind"] == "Deployment")
    ann = deploy["spec"]["template"]["metadata"]["annotations"]
    assert ann["prometheus.io/scrape"] == "true"
    assert ann["prometheus.io/port"] == str(PORT)


def test_every_endpoint_has_conditions_and_a_unique_key():
    endpoints = _config(_synth())["endpoints"]
    assert endpoints
    assert all(e["conditions"] for e in endpoints)
    keys = [(e["group"], e["name"]) for e in endpoints]
    assert len(keys) == len(set(keys))


def test_no_gatus_alerting_providers():
    # Grafana is the one pager; see the module docstring.
    assert "alerting" not in _config(_synth())


def _argo_appsets(cluster):
    app = K8sTesting.app()
    chart = ArgoCDChart(app, "argocd", cluster=cluster)
    return {
        o["metadata"]["name"]
        for o in K8sTesting.synth(chart)
        if o["kind"] == "ApplicationSet"
    }


def test_minipc_only():
    assert "gatus" in _argo_appsets("minipc")
    assert "gatus" not in _argo_appsets("k3d")


def test_alert_pages_on_exactly_the_paging_groups():
    # The rule's group regex and PAGING_GROUPS are two copies of one list.
    import pathlib
    import re

    from adanalife_k8s.constructs.gatus import PAGING_GROUPS

    tf = (
        pathlib.Path(__file__).parents[3] / "terraform/platform/grafana-alerts.tf"
    ).read_text()
    m = re.search(r'gatus_results_endpoint_success\{[^}]*group=~\\"([^\\]+)\\"', tf)
    assert m, "gatus-health rule lost its group filter"
    assert set(m.group(1).split("|")) == set(PAGING_GROUPS)


def test_every_endpoint_group_is_known():
    from adanalife_k8s.constructs.gatus import PAGING_GROUPS

    context = {"upstream", "public", "nas", "stage"}
    groups = {e["group"] for e in _config(_synth())["endpoints"]}
    assert groups <= set(PAGING_GROUPS) | context


def test_history_persists_on_a_claim():
    objs = _synth()
    assert _config(objs)["storage"]["type"] == "sqlite"
    assert any(o["kind"] == "PersistentVolumeClaim" for o in objs)
    deploy = next(o for o in objs if o["kind"] == "Deployment")
    assert deploy["spec"]["strategy"]["type"] == "Recreate"


def _data_policy_sources(env_name):
    import pathlib

    doc = pathlib.Path(__file__).parents[2] / "dist" / f"{env_name}-data.k8s.yaml"
    policy = next(
        o
        for o in yaml.safe_load_all(doc.read_text())
        if o and o["kind"] == "NetworkPolicy"
    )
    return {
        peer.get("namespaceSelector", {})
        .get("matchLabels", {})
        .get("kubernetes.io/metadata.name")
        for rule in policy["spec"]["ingress"]
        for peer in rule["from"]
    }


def test_postgres_policy_admits_gatus_in_prod_only():
    # A missing rule fails as a silent TCP timeout, not an error.
    assert "gatus" in _data_policy_sources("prod-1")
    assert "gatus" not in _data_policy_sources("stage-1")
