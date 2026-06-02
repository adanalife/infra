"""Deploy units. Each Chart synthesizes to one file in dist/ and is applied
independently — `AppsChart` per env, `PlatformChart` per cluster (later) — so
the platform stack stays decoupled from any app env.
"""
from __future__ import annotations

from cdk8s import Chart
from constructs import Construct

from adanalife_k8s.config import EnvConfig


class AppsChart(Chart):
    """App workloads for one environment (obs, vlc, tripbot, postgres).

    Phase 0: empty. Phase 1 adds the per-platform OBS instances; later phases
    add vlc/tripbot/postgres.
    """

    def __init__(self, scope: Construct, id: str, *, env: EnvConfig):
        super().__init__(scope, id, namespace=env.namespace or None)
        self.env = env
        # constructs added in subsequent phases
