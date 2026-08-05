"""Music volume tests — the node-local claim the album bed plays from, and the
copy script that fills it from the NAS.

The manifest assertions guard a cross-repo contract: obs and tripbot both name
`obs-music-local` verbatim, so a rename here silently strands their pods on an
unbound claim (which, because OBS deploys Recreate, takes the stream off the
air). The script test covers the resume-after-truncation path, which is the
reason the Job doesn't just run `cp -r`."""

import subprocess

from cdk8s import Testing as K8sTesting

from adanalife_k8s.charts import MusicLocalizeChart, SupportingChart
from adanalife_k8s.constructs.music import _LOCALIZE_SCRIPT, LOCAL_CLAIM
from adanalife_k8s.config import load_env


def _synth(chart_cls, env_name):
    app = K8sTesting.app()
    return K8sTesting.synth(chart_cls(app, "t", env=load_env(env_name)))


def _one(objs, kind, name):
    hits = [o for o in objs if o["kind"] == kind and o["metadata"]["name"] == name]
    assert len(hits) == 1, f"expected exactly one {kind}/{name}, got {len(hits)}"
    return hits[0]


def test_local_music_claim_is_node_local_on_nfs_envs():
    for env_name in ("prod-1", "stage-1"):
        pvc = _one(
            _synth(SupportingChart, env_name), "PersistentVolumeClaim", LOCAL_CLAIM
        )
        # local-path (not "") is what keeps the bed off the NAS: it provisions on
        # the T5 UserVolume, so no live pod mounts NFS.
        assert pvc["spec"]["storageClassName"] == "local-path"
        # local-path is node-local, so RWO is the only honest access mode.
        assert pvc["spec"]["accessModes"] == ["ReadWriteOnce"]


def test_local_music_claim_absent_on_hostpath_envs():
    # local/dev have no NAS to mirror from; OBS falls back to the carhum bed.
    objs = _synth(SupportingChart, "local")
    assert not [o for o in objs if o["metadata"]["name"] == LOCAL_CLAIM]


def test_localize_job_writes_the_claim_and_pins_to_the_local_path_node():
    job = _one(_synth(MusicLocalizeChart, "prod-1"), "Job", "music-localize")
    spec = job["spec"]["template"]["spec"]
    # The local volume only exists on the minipc, so the copy has to run there.
    assert spec["nodeSelector"] == {"kubernetes.io/hostname": "adanalife-minipc"}
    # Preempted before the live stream is, since it does bulk NAS reads.
    assert spec["priorityClassName"] == "dashcam-cv-low"
    local = [v for v in spec["volumes"] if v["name"] == "local"][0]
    assert local["persistentVolumeClaim"]["claimName"] == LOCAL_CLAIM
    # NFS is the source and must stay read-only; the local claim is the only
    # thing this Job writes.
    nfs_mount = [m for m in spec["containers"][0]["volumeMounts"] if m["name"] == "nfs"]
    assert nfs_mount[0]["readOnly"] is True


def _run(src, dst):
    return subprocess.run(
        ["sh", "-c", _LOCALIZE_SCRIPT],
        env={"SRC": str(src), "DST": str(dst), "PATH": "/usr/bin:/bin"},
        capture_output=True,
        text=True,
        check=True,
    )


def test_localize_script_mirrors_resumes_and_is_idempotent(tmp_path):
    src, dst = tmp_path / "nfs", tmp_path / "local"
    # A space in the album name, like every real StreamBeats album ("Lone Wolf").
    album = src / "streambeats-synthwave-lone wolf"
    album.mkdir(parents=True)
    (album / "01 Intro.mp3").write_text("full track")
    dst.mkdir()

    _run(src, dst)
    copied = dst / "streambeats-synthwave-lone wolf" / "01 Intro.mp3"
    assert copied.read_text() == "full track"
    # The staging dir is cleaned up, so nothing outside an album tree is left for
    # the track scanner to find.
    assert not (dst / ".partial").exists()

    # An interrupted copy leaves a short file. Size comparison (not mtime) is what
    # catches it — a truncated track would otherwise play as a glitch forever.
    copied.write_text("trunc")
    _run(src, dst)
    assert copied.read_text() == "full track"

    # Re-running with everything present is a no-op, so topping up after staging
    # new albums only does the new work.
    before = copied.stat().st_mtime_ns
    out = _run(src, dst)
    assert copied.stat().st_mtime_ns == before
    assert "01 Intro.mp3" not in out.stdout
