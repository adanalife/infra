"""Phase 0 smoke tests: the harness synths and the env table loads."""

from cdk8s import (
    Testing as K8sTesting,
)  # aliased so pytest doesn't collect it as a test class

from adanalife_k8s.charts import AppsChart
from adanalife_k8s.config import ENVS, load_env


def test_all_envs_load():
    for name in ENVS:
        assert load_env(name).name == name


def test_appschart_synthesizes_per_env():
    for name in ENVS:
        app = K8sTesting.app()
        chart = AppsChart(app, f"{name}-apps", env=load_env(name))
        manifests = K8sTesting.synth(chart)
        # Phase 0: chart is empty; assert synth runs without error.
        assert isinstance(manifests, list)
