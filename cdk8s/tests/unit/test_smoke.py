"""Smoke tests: the env table loads. The app charts moved to the tripbot repo
(their synth is gated there); infra's per-env supporting/data units are exercised
by test_data_namespace.py."""

from adanalife_k8s.config import ENVS, load_env


def test_all_envs_load():
    for name in ENVS:
        assert load_env(name).name == name


def test_stage_dashcam_path_overrides_without_touching_prod(monkeypatch):
    """STAGE_NFS_PATH repoints only stage's dashcam mount (so it can stream the
    regenerated corpus); prod always reads the shared NFS_PATH airing export, and
    an unset override leaves stage on NFS_PATH too."""
    monkeypatch.setenv("NFS_SERVER", "nas")
    monkeypatch.setenv("NFS_PATH", "/airing/_all")
    monkeypatch.delenv("STAGE_NFS_PATH", raising=False)
    assert load_env("stage-1").nfs_path == "/airing/_all"  # unset → shared export

    monkeypatch.setenv("STAGE_NFS_PATH", "/regen/_opt/clips")
    assert load_env("stage-1").nfs_path == "/regen/_opt/clips"  # stage flips
    assert load_env("prod-1").nfs_path == "/airing/_all"  # prod never does


def test_dashcam_golden_render_uses_placeholders(monkeypatch):
    """With no coords in the env (the committed-golden synth), every nfs env —
    stage included — renders the placeholder, so the override adds no golden diff."""
    for var in ("NFS_SERVER", "NFS_PATH", "STAGE_NFS_PATH"):
        monkeypatch.delenv(var, raising=False)
    for name in ENVS:
        env = load_env(name)
        if env.dashcam_mode == "nfs":
            assert env.nfs_path == "<export path>"
