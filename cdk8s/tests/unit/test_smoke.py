"""Smoke tests: the harness synths and the env table loads."""

from cdk8s import App

from adanalife_k8s.charts import emit_app_charts
from adanalife_k8s.config import ENVS, load_env


def test_all_envs_load():
    for name in ENVS:
        assert load_env(name).name == name


def test_app_charts_synthesize_per_env(tmp_path):
    for name in ENVS:
        env = load_env(name)
        app = App(outdir=str(tmp_path / name))
        emit_app_charts(app, env)
        app.synth()
        # one dist file per (component, platform): 4 components × len(platforms)
        produced = list((tmp_path / name).glob("*.k8s.yaml"))
        assert len(produced) == 4 * len(env.platforms)
