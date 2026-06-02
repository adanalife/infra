"""Deploy units. Each Chart synthesizes to one file in dist/ and is applied
independently — `AppsChart` per env, `PlatformChart` per cluster (later) — so
the platform stack stays decoupled from any app env.
"""
from __future__ import annotations

from cdk8s import Chart
from constructs import Construct

from adanalife_k8s.config import EnvConfig
from adanalife_k8s.constructs.obs import ObsInstance


class AppsChart(Chart):
    """App workloads for one environment (obs now; vlc/tripbot/postgres later)."""

    def __init__(self, scope: Construct, id: str, *, env: EnvConfig):
        super().__init__(scope, id, namespace=env.namespace or None)
        self.env = env

        # --- OBS, one instance per streaming platform present in this env ---
        for platform in env.platforms:
            # twitch streams by default in prod (ESO stream-key); everything else
            # boots idle until toggled on. youtube carries STREAM_PLATFORM=youtube.
            streaming = platform == "twitch" and env.name == "prod-1"
            ObsInstance(
                self, platform, env=env,
                streaming=streaming,
                stream_key_sm=f"k8s/obs/{platform}-stream-key" if streaming else None,
                extra_config={"STREAM_PLATFORM": "youtube"} if platform == "youtube" else None,
            )
