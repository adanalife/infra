"""Render-parity gate: the cdk8s synth must reproduce the legacy Kustomize render
for every env, modulo the documented intended divergences (see tests/parity.py).

Synthesizes fresh into dist/ with the reference's NFS placeholders so the dashcam
PV/PVC line up, then asserts zero drift per env. This is the migration's safety
net — if a construct change diverges from what Kustomize deployed, it fails here.
"""

import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent.parent
ENVS = ["development", "stage-1", "prod-1", "local"]


@pytest.fixture(scope="module")
def synthed():
    """Synth all envs with the reference NFS placeholders (so PV/PVC match)."""
    if not (ROOT / "reference").exists():
        pytest.skip("reference/ renders absent (run the kustomize capture first)")
    env = {
        **os.environ,
        "NFS_SERVER": "<NFS server address>",
        "NFS_PATH": "<export path>",
    }
    subprocess.run(
        ["uv", "run", "cdk8s", "synth"],
        cwd=ROOT,
        env=env,
        check=True,
        capture_output=True,
    )
    sys.path.insert(0, str(ROOT))
    from tests.parity import compare

    return compare


@pytest.mark.parametrize("env", ENVS)
def test_env_matches_kustomize(synthed, env):
    problems = synthed(env)
    assert not problems, f"{env} drifted from kustomize:\n  " + "\n  ".join(problems)
