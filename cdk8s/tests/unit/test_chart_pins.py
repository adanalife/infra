"""platform-charts/Chart.yaml is the version table for every platform Helm
release, and the file Dependabot watches. Each release must be pinned there,
against the same repository the synth and Argo pull the chart from — otherwise
Dependabot would propose versions from a repo the cluster never reads.
"""

from adanalife_k8s.config import load_env
from adanalife_k8s.helm_platform import (
    PINS,
    REPOS,
    cluster_components,
    env_components,
)


def _components():
    comps = cluster_components("minipc", load_env("prod-1"))
    comps += cluster_components("k3d", load_env("development"))
    for env in ("prod-1", "stage-1", "development"):
        comps += env_components(load_env(env))
    return comps


def test_every_release_is_pinned_against_its_own_repo():
    repos = {d["name"]: d["repository"].removeprefix("oci://") for d in PINS}
    for c in _components():
        assert c.version_key == c.chart, c.release
        assert repos[c.chart] == REPOS[c.repo_key], c.release


def test_no_pin_is_orphaned_or_duplicated():
    names = [d["name"] for d in PINS]
    assert len(names) == len(set(names))
    assert set(names) == {c.chart for c in _components()}
