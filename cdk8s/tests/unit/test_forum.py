"""Forum tests.

Pins the two-copy facts: the image tag is the commit the workflow builds, and
Rails gets a URL for each of its four databases, three of which CNPG creates.
"""

import pathlib
import re

from cdk8s import Chart
from cdk8s import Testing as K8sTesting

from adanalife_k8s.charts import ArgoCDChart
from adanalife_k8s.constructs.forum import EXTRA_DATABASES, HOST, IMAGE, Forum


def _synth():
    app = K8sTesting.app()
    chart = Chart(app, "t")
    Forum(chart)
    return K8sTesting.synth(chart)


def test_image_tag_is_the_commit_the_workflow_builds():
    wf = (
        pathlib.Path(__file__).parents[3] / ".github/workflows/forum-image.yml"
    ).read_text()
    ref = re.search(r"UPSTREAM_REF: ([0-9a-f]{40})", wf).group(1)
    assert IMAGE == f"ghcr.io/adanalife/forum:{ref}"


def test_every_extra_database_exists_and_has_a_url():
    objs = _synth()
    created = {o["spec"]["name"] for o in objs if o["kind"] == "Database"}
    deploy = next(o for o in objs if o["kind"] == "Deployment")
    env = {
        e["name"]: e.get("value", "")
        for e in deploy["spec"]["template"]["spec"]["containers"][0]["env"]
    }
    assert len(created) == len(EXTRA_DATABASES)
    for db in EXTRA_DATABASES:
        url = env[f"{db.upper()}_DATABASE_URL"]
        assert url.rsplit("/", 1)[1] in created
    assert "DATABASE_URL" in env and "SECRET_KEY_BASE" in env


def test_rails_admits_the_ingress_host():
    objs = _synth()
    ingress = next(o for o in objs if o["kind"] == "Ingress")
    assert ingress["spec"]["rules"][0]["host"] == HOST
    cm = next(o for o in objs if o["kind"] == "ConfigMap")
    assert HOST in next(iter(cm["data"].values()))


def _appsets(cluster):
    app = K8sTesting.app()
    chart = ArgoCDChart(app, "argocd", cluster=cluster)
    return {
        o["metadata"]["name"]: o
        for o in K8sTesting.synth(chart)
        if o["kind"] == "ApplicationSet"
    }


def test_minipc_only_and_never_pruned():
    assert "forum" not in _appsets("k3d")
    spec = _appsets("minipc")["forum"]["spec"]["template"]["spec"]
    assert "Prune=false" in spec["syncPolicy"]["syncOptions"]
