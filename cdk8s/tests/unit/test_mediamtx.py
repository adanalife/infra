"""MediaMTX relay tests — the declared replica count per env.

Replica counts on platform workloads are runtime-owned (the mediamtx appset
ignores .spec.replicas), so what git declares is only the birth state. Stage
births parked and a console scale-up activates it; prod declares its relay live
because it carries the broadcast. A flip either way is silent — the synthed
dist just changes — so it's asserted here.
"""

from cdk8s import Testing as K8sTesting

from adanalife_k8s.charts import MediamtxChart
from adanalife_k8s.config import load_env


def _replicas(env_name, platform="twitch"):
    app = K8sTesting.app()
    chart = MediamtxChart(app, "t", env=load_env(env_name), platform=platform)
    deploys = [o for o in K8sTesting.synth(chart) if o["kind"] == "Deployment"]
    assert len(deploys) == 1
    return deploys[0]["spec"]["replicas"]


def test_stage_relays_are_declared_parked():
    assert _replicas("stage-1") == 0


def test_prod_relays_are_declared_live():
    assert _replicas("prod-1") == 1
