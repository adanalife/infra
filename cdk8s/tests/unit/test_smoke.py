"""Smoke tests: the env table loads. The app charts moved to the tripbot repo
(their synth is gated there); infra's per-env supporting/data units are exercised
by test_data_namespace.py."""

from adanalife_k8s.config import ENVS, load_env


def test_all_envs_load():
    for name in ENVS:
        assert load_env(name).name == name
