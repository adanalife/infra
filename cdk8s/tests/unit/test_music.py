"""Music volume tests — the node-local claim the album bed plays from, and the
copy script that fills it from the NAS.

The manifest assertions guard a cross-repo contract: obs and tripbot both name
`obs-music-local` verbatim, so a rename here silently strands their pods on an
unbound claim (which, because OBS deploys Recreate, takes the stream off the
air). The script test covers the resume-after-truncation path, which is the
reason the Job doesn't just run `cp -r`, and the index it renders — the file
tripbot reads to know the library exists at all, so an empty or malformed one is
a silent stream of dead air (2026-09-08)."""

import json
import subprocess

import yaml

from cdk8s import Testing as K8sTesting

from adanalife_k8s.charts import MusicLocalizeChart, SupportingChart
from adanalife_k8s.constructs.music import (
    _AUDIO_EXTS,
    _LOCALIZE_SCRIPT,
    INDEX_CONFIGMAP,
    INDEX_KEY,
    LOCAL_CLAIM,
    POD_MUSIC_DIR,
)
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
    # thing this Job writes. The copy is the initContainer — the container proper
    # publishes the index and touches neither volume.
    copy = spec["initContainers"][0]
    nfs_mount = [m for m in copy["volumeMounts"] if m["name"] == "nfs"]
    assert nfs_mount[0]["readOnly"] is True
    assert not [
        m
        for m in spec["containers"][0]["volumeMounts"]
        if m["name"] in ("nfs", "local")
    ]


def _run(src, dst, out=None):
    """The Job's copy step, against tmp dirs. OUT/CM/KEY/POD have no defaults in
    the script — the container env supplies them — so passing them here is what
    keeps this test honest about the contract the Job actually runs under."""
    return subprocess.run(
        ["sh", "-c", _LOCALIZE_SCRIPT],
        env={
            "SRC": str(src),
            "DST": str(dst),
            "OUT": str(out if out is not None else dst.parent / "cm.yaml"),
            "CM": INDEX_CONFIGMAP,
            "KEY": INDEX_KEY,
            "POD": POD_MUSIC_DIR,
            "PATH": "/usr/bin:/bin",
        },
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


def _index(src, dst, tmp_path):
    """Run the script and return the album index it published, parsed."""
    out = tmp_path / "cm.yaml"
    _run(src, dst, out)
    doc = yaml.safe_load(out.read_text())
    assert doc["kind"] == "ConfigMap"
    # No namespace: kubectl in-cluster applies it into the pod's own, which is
    # where the tripbot Deployments mount it from.
    assert "namespace" not in doc["metadata"]
    assert doc["metadata"]["name"] == INDEX_CONFIGMAP
    return json.loads(doc["data"][INDEX_KEY])


def test_index_names_pod_paths_and_skips_what_is_not_a_track(tmp_path):
    src, dst = tmp_path / "nfs", tmp_path / "local"
    album = src / "streambeats-synthwave-lone wolf"
    album.mkdir(parents=True)
    (album / "01 Intro.mp3").write_text("track")
    (album / "cover.jpg").write_text("art")
    # The NAS is a Synology, which litters every directory with an @eaDir of
    # sidecars named `<track>.mp3@SynoEAStream`. They copy across like anything
    # else; what keeps them out of the index is that the extension test is on the
    # whole name, so they match neither .mp3 nor anything else in _AUDIO_EXTS.
    (album / "@eaDir").mkdir()
    (album / "@eaDir" / "01 Intro.mp3@SynoEAStream").write_text("junk")
    # The carhum lives at the share root, outside any album — it is the fallback
    # bed baked into the OBS image, not something the album bed should offer.
    (src / "carsounds.m4a").write_text("drone")
    dst.mkdir()

    index = _index(src, dst, tmp_path)

    assert list(index) == ["streambeats-synthwave-lone wolf"]
    # Absolute paths as OBS sees them, not paths on the share or in this Job —
    # tripbot hands them to OBS, which resolves them against its own mount.
    assert index["streambeats-synthwave-lone wolf"] == [
        f"{POD_MUSIC_DIR}/streambeats-synthwave-lone wolf/01 Intro.mp3"
    ]


def test_index_escapes_names_that_would_break_the_json(tmp_path):
    # Nothing on the share is named like this today, but a hand-staged album
    # that is would otherwise emit JSON tripbot can't parse — and an unreadable
    # index reads to the bed as no albums at all, which is dead air.
    src, dst = tmp_path / "nfs", tmp_path / "local"
    album = src / 'a "quoted" \\ name'
    album.mkdir(parents=True)
    (album / "01.mp3").write_text("track")
    dst.mkdir()

    index = _index(src, dst, tmp_path)

    assert list(index) == ['a "quoted" \\ name']


def test_index_covers_every_audio_extension_the_bed_plays(tmp_path):
    src, dst = tmp_path / "nfs", tmp_path / "local"
    album = src / "mixed"
    album.mkdir(parents=True)
    for i, ext in enumerate(_AUDIO_EXTS):
        (album / f"{i:02d} track.{ext}").write_text("track")
    dst.mkdir()

    index = _index(src, dst, tmp_path)

    # The find expression is written out in the script; this is what stops it
    # drifting from the constant tripbot's bin/stage-streambeats agrees with.
    assert len(index["mixed"]) == len(_AUDIO_EXTS)


def test_index_is_rebuilt_from_the_local_copy_not_the_share(tmp_path):
    # An album pulled off the share has to leave the index on the next run, and
    # an album that has not finished copying must not appear in it — the index is
    # a claim about what the bed can actually play right now.
    src, dst = tmp_path / "nfs", tmp_path / "local"
    for name in ("keep", "drop"):
        (src / name).mkdir(parents=True)
        (src / name / "01.mp3").write_text("track")
    dst.mkdir()

    assert sorted(_index(src, dst, tmp_path)) == ["drop", "keep"]

    (src / "drop" / "01.mp3").unlink()
    (src / "drop").rmdir()
    (dst / "drop" / "01.mp3").unlink()
    (dst / "drop").rmdir()

    assert sorted(_index(src, dst, tmp_path)) == ["keep"]


def test_localize_job_publishes_the_index_after_the_copy():
    objs = _synth(MusicLocalizeChart, "prod-1")
    job = _one(objs, "Job", "music-localize")
    spec = job["spec"]["template"]["spec"]

    # The copy is an initContainer and the apply is the container proper, which
    # is the only thing ordering them: the index must describe a finished mirror.
    assert [c["name"] for c in spec["initContainers"]] == ["localize"]
    assert [c["name"] for c in spec["containers"]] == ["publish-index"]
    publish = spec["containers"][0]
    assert publish["args"][:2] == ["apply", "-f"]

    # Both steps see the same handoff file, and it is the one the script writes.
    handoff = publish["args"][2]
    env = {e["name"]: e["value"] for e in spec["initContainers"][0]["env"]}
    assert env["OUT"] == handoff
    assert env["CM"] == INDEX_CONFIGMAP and env["KEY"] == INDEX_KEY
    assert env["POD"] == POD_MUSIC_DIR
    # An emptyDir, not the music claim — nothing the bed reads should carry the
    # Job's scratch state.
    assert [v for v in spec["volumes"] if v["name"] == "handoff"][0]["emptyDir"] == {}


def test_index_publisher_can_only_touch_the_one_configmap():
    objs = _synth(MusicLocalizeChart, "prod-1")
    role = _one(objs, "Role", "music-localize")
    binding = _one(objs, "RoleBinding", "music-localize")
    _one(objs, "ServiceAccount", "music-localize")

    verbs = {v for rule in role["rules"] for v in rule["verbs"]}
    # This Job runs on the node the live stream runs on. It may not delete the
    # index the bed is playing off, and it may not enumerate the namespace's
    # other ConfigMaps.
    assert "delete" not in verbs and "list" not in verbs
    named = [r for r in role["rules"] if "resourceNames" in r]
    assert named and all(r["resourceNames"] == [INDEX_CONFIGMAP] for r in named)
    # `create` is the one verb the API cannot scope by name — the object does not
    # exist yet — so it is the only rule allowed to omit resourceNames.
    assert all("resourceNames" in r or r["verbs"] == ["create"] for r in role["rules"])
    assert binding["roleRef"]["name"] == "music-localize"
    assert binding["subjects"][0]["name"] == "music-localize"


def test_index_rbac_absent_on_hostpath_envs():
    # No NAS to mirror, so no Job, so nothing needs the credential.
    objs = _synth(MusicLocalizeChart, "local")
    assert not [
        o for o in objs if o["kind"] in ("Role", "RoleBinding", "ServiceAccount")
    ]
