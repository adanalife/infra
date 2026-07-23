"""Cluster scheduling priority tiers — the owner of the fleet's PriorityClasses.

The single-node minipc runs prod and stage as co-tenants, so under pod-count or
CPU pressure the scheduler needs a fixed pecking order: which workloads get a
slot, and which get preempted. These classes define it, above the default (0)
tier every stage and batch pod stays on and the dashcam-cv-low (-10)
most-preemptible tier:

  prod-stream  (1000)  live-stream-critical — tripbot, obs, playout, mediamtx,
                       gateway. Preempts default-priority co-tenants under node
                       pressure; only the system tiers outrank it.
  prod-support  (900)  prod-important but not the broadcast — the console. Below
                       prod-stream, so it preempts stage/batch to schedule but
                       never evicts a broadcasting pod.

Cluster-scoped (one per cluster), so emitted once, in the prod-1 SupportingChart
— the apiserver ignores the namespace cdk8s stamps on a cluster-scoped kind.
Every app repo references a class by name; this module is the single definition.
"""

from __future__ import annotations

from constructs import Construct

import imports.k8s as k8s
from adanalife_k8s.config import EnvConfig

PROD_STREAM = "prod-stream"
PROD_SUPPORT = "prod-support"


def emit_priority_classes(scope: Construct, env: EnvConfig) -> None:
    """The cluster's scheduling tiers. Emitted only for prod-1 — the delivery
    vehicle for these cluster-scoped objects. Stage/dev workloads stay on the
    default (0) tier by design: they're the co-tenants prod preempts."""
    if env.name != "prod-1":
        return

    k8s.KubePriorityClass(
        scope,
        "priority-prod-stream",
        metadata=k8s.ObjectMeta(name=PROD_STREAM),
        value=1000,
        global_default=False,
        description=(
            "Live-stream workloads — outrank default-priority co-tenants; "
            "preempt them under node pressure."
        ),
    )
    k8s.KubePriorityClass(
        scope,
        "priority-prod-support",
        metadata=k8s.ObjectMeta(name=PROD_SUPPORT),
        value=900,
        global_default=False,
        description=(
            "Prod support workloads (the console) — outrank default-priority "
            "co-tenants and preempt them under node pressure, but stay below the "
            "live-stream tier (prod-stream)."
        ),
    )
