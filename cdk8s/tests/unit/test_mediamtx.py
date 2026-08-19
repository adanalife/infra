"""MediaMTX relay tests — the declared replica count per env, and the
publisher-takeover posture of the dashcam path.

Replica counts on platform workloads are runtime-owned (the mediamtx appset
ignores .spec.replicas), so what git declares is only the birth state. Every env
births parked and a console scale-up activates the relay. A flip either way is
silent — the synthed dist just changes — so it's asserted here.
"""

import pytest
from cdk8s import Testing as K8sTesting

from adanalife_k8s.charts import MediamtxChart
from adanalife_k8s.config import load_env


def _synth(env_name, platform="twitch"):
    app = K8sTesting.app()
    chart = MediamtxChart(app, "t", env=load_env(env_name), platform=platform)
    return K8sTesting.synth(chart)


def _replicas(env_name):
    deploys = [o for o in _synth(env_name) if o["kind"] == "Deployment"]
    assert len(deploys) == 1
    return deploys[0]["spec"]["replicas"]


@pytest.mark.parametrize("env_name", ["stage-1", "prod-1"])
def test_relays_are_declared_parked(env_name):
    assert _replicas(env_name) == 0


@pytest.mark.parametrize("env_name", ["stage-1", "prod-1"])
def test_dashcam_path_rejects_a_second_publisher(env_name):
    # playout's rolling deploys assume a held path can't be stolen: the
    # incoming pod waits for it to free. MediaMTX's default (kick the current
    # publisher) would reintroduce the takeover this guards against, so the
    # override must stay declared on the path.
    cms = [o for o in _synth(env_name) if o["kind"] == "ConfigMap"]
    assert len(cms) == 1
    config = cms[0]["data"]["mediamtx.yml"]
    assert "overridePublisher: no" in config.split("dashcam:", 1)[1]
