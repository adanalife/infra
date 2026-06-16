"""The dashcam NFS storage primitives — the cluster-scoped PersistentVolume and
the namespace PersistentVolumeClaim that the vlc-server pods mount read-only.

These are DATA infra (they outlive the stateless app workloads), so they stay in
infra even though the vlc-server *app* manifests now live in the tripbot repo:
the PV/PVC are emitted into infra's DataChart / DashcamPVChart, while the vlc
Deployment that mounts the `vlc-dashcam` claim is synthesized from the tripbot
repo and references it by name (a cross-repo coupling on the claim name, same as
the materialized-Secret names).
"""

from __future__ import annotations

import imports.k8s as k8s
from constructs import Construct

from adanalife_k8s.config import EnvConfig


def emit_dashcam_pvc(scope: Construct, env: EnvConfig) -> None:
    """The dashcam PVC — Argo-managed, emitted into DataChart (not the vlc app) so
    the stateless vlc Deployment can churn without disturbing it. Binds 1:1 by
    name (volumeName + storageClassName "") to the cluster-scoped NFS PV that's
    provisioned out-of-band — see emit_dashcam_pv / `task k8s:<env>:dashcam-pv`.
    No host specifics here, so it's safe in the committed dist. No-op on hostPath
    envs (local/dev), where the dashcam volume is an inline hostPath. Shared
    across platforms (ReadOnlyMany), so it stays a single non-per-platform PVC."""
    if env.dashcam_mode != "nfs":
        return
    ns = env.namespace or None
    k8s.KubePersistentVolumeClaim(
        scope,
        "dashcam-pvc",
        metadata=k8s.ObjectMeta(name="vlc-dashcam", namespace=ns),
        spec=k8s.PersistentVolumeClaimSpec(
            access_modes=["ReadOnlyMany"],
            storage_class_name="",
            volume_name=env.nfs_pv_name,
            resources=k8s.ResourceRequirements(
                requests={"storage": k8s.Quantity.from_string("1Ti")}
            ),
        ),
    )


def emit_dashcam_pv(scope: Construct, env: EnvConfig) -> None:
    """The dashcam NFS PersistentVolume — cluster-scoped, host-specific bootstrap
    infrastructure deliberately kept OUTSIDE Argo's reconcile loop. It lives in
    its own DashcamPVChart -> dist/<env>-dashcam-pv.k8s.yaml, which neither the
    apps nor data ApplicationSet globs, and is provisioned once per cluster via
    `task k8s:<env>:dashcam-pv`. That task synths this with the real NFS coords
    from the gitignored cdk8s/dashcam-nfs.local.env; the committed golden carries
    the `<NFS server address>` / `<export path>` placeholders, so no host
    specifics ever land in git. Reclaim policy is Retain — the corpus lives on
    the external NFS server, untouched by object deletion. Stage shares prod's
    export read-only but needs its own PV name (PVs bind 1:1) — env.nfs_pv_name.
    No-op on hostPath envs."""
    if env.dashcam_mode != "nfs":
        return
    k8s.KubePersistentVolume(
        scope,
        "dashcam-pv",
        metadata=k8s.ObjectMeta(name=env.nfs_pv_name),
        spec=k8s.PersistentVolumeSpec(
            capacity={"storage": k8s.Quantity.from_string("1Ti")},
            access_modes=["ReadOnlyMany"],
            persistent_volume_reclaim_policy="Retain",
            storage_class_name="",
            nfs=k8s.NfsVolumeSource(
                server=env.nfs_server, path=env.nfs_path, read_only=True
            ),
        ),
    )
