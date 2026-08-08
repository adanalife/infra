"""MediaMTX relay tests — the declared replica count per env.

Replica counts on platform workloads are runtime-owned (the mediamtx appset
ignores .spec.replicas), so what git declares is only the birth state. Every env
births parked and a console scale-up activates the relay. A flip either way is
silent — the synthed dist just changes — so it's asserted here.
"""

import pytest
from cdk8s import Testing as K8sTesting

from adanalife_k8s.charts import MediamtxChart
from adanalife_k8s.config import load_env


def _replicas(env_name, platform="twitch"):
    app = K8sTesting.app()
    chart = MediamtxChart(app, "t", env=load_env(env_name), platform=platform)
    deploys = [o for o in K8sTesting.synth(chart) if o["kind"] == "Deployment"]
    assert len(deploys) == 1
    return deploys[0]["spec"]["replicas"]


@pytest.mark.parametrize("env_name", ["stage-1", "prod-1"])
def test_relays_are_declared_parked(env_name):
    assert _replicas(env_name) == 0
