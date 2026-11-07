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
