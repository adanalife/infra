"""Smoke tests: the env table loads. The app charts moved to the tripbot repo
(their synth is gated there); infra's per-env supporting/data units are exercised
by test_data_namespace.py."""

from adanalife_k8s.config import ENVS, load_env


def test_all_envs_load():
    for name in ENVS:
        assert load_env(name).name == name


def test_dashcam_envs_converge_on_shared_path(monkeypatch):
    """Both prod and stage read the shared NFS_PATH (now the canonical regenerated
    _opt/clips corpus) — the temporary STAGE_NFS_PATH override that let stage run
    ahead during the regen has been retired, so it no longer repoints stage. The
    per-env override mechanism stays generic (config.py nfs_path_env) for the next
    time one env needs to diverge."""
    monkeypatch.setenv("NFS_SERVER", "nas")
    monkeypatch.setenv("NFS_PATH", "/regen/_opt/clips")
    monkeypatch.setenv("STAGE_NFS_PATH", "/somewhere/else")  # retired → no effect
    assert load_env("prod-1").nfs_path == "/regen/_opt/clips"
    assert load_env("stage-1").nfs_path == "/regen/_opt/clips"


def test_dashcam_golden_render_uses_placeholders(monkeypatch):
    """With no coords in the env (the committed-golden synth), every nfs env —
    stage included — renders the placeholder, so the override adds no golden diff."""
    for var in ("NFS_SERVER", "NFS_PATH", "STAGE_NFS_PATH"):
        monkeypatch.delenv(var, raising=False)
    for name in ENVS:
        env = load_env(name)
        if env.dashcam_mode == "nfs":
            assert env.nfs_path == "<export path>"
