"""Dashcam localize script test — the copy that fills the node-local corpus PVC
from the NAS, run against tmp dirs.

The corpus is hundreds of GB, so the two paths that make a re-run safe are the
ones worth pinning: the size check that skips a clip already fully present, and
the `.partial` write-then-rename that keeps an interrupted copy from ever looking
done. The script is GNU find/stat only (the Job's ubuntu image), so this skips on
a host without them; CI's Linux runners execute it."""

import subprocess

import pytest

from adanalife_k8s.constructs.dashcam import _LOCALIZE_SCRIPT

_GNU = (
    subprocess.run(
        "find /dev/null -maxdepth 0 -printf '' && stat -c%s /dev/null",
        shell=True,
        capture_output=True,
    ).returncode
    == 0
)

pytestmark = pytest.mark.skipif(not _GNU, reason="needs GNU find -printf / stat -c")


def _run(src, dst):
    return subprocess.run(
        ["sh", "-c", _LOCALIZE_SCRIPT],
        env={"SRC": str(src), "DST": str(dst), "WORKERS": "2", "PATH": "/usr/bin:/bin"},
        capture_output=True,
        text=True,
        check=True,
    )


def test_localize_script_mirrors_resumes_and_is_idempotent(tmp_path):
    src, dst = tmp_path / "nfs", tmp_path / "local"
    src.mkdir()
    dst.mkdir()
    (src / "2018_0101_000000_001.MP4").write_text("full clip")
    (src / "2018_0101_000100_002.MP4").write_text("same")
    (src / "notes.txt").write_text("not a clip")
    # Same size, different bytes: only the size check can explain it surviving.
    (dst / "2018_0101_000100_002.MP4").write_text("SAME")
    # A killed run leaves its temp behind; the next run overwrites and renames it.
    (dst / ".2018_0101_000000_001.MP4.partial").write_text("ful")

    _run(src, dst)
    copied = dst / "2018_0101_000000_001.MP4"
    assert copied.read_text() == "full clip"
    assert (dst / "2018_0101_000100_002.MP4").read_text() == "SAME"
    assert sorted(p.name for p in dst.iterdir()) == [
        "2018_0101_000000_001.MP4",
        "2018_0101_000100_002.MP4",
    ]

    # A short file at the final name (copied by hand, or a pre-.partial run) fails
    # the size check and is replaced.
    copied.write_text("trunc")
    _run(src, dst)
    assert copied.read_text() == "full clip"

    # Re-running with everything present is a no-op, so topping up new clips only
    # does the new work.
    before = copied.stat().st_mtime_ns
    _run(src, dst)
    assert copied.stat().st_mtime_ns == before
