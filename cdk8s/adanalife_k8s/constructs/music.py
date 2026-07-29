"""The background-music NFS storage primitives — the cluster-scoped
PersistentVolume and the namespace PersistentVolumeClaim the OBS pods mount
read-only to play an album as the stream's background audio bed.

Same split as the dashcam volumes next door: the PVC is Argo-managed and safe to
commit (no host specifics), while the PV carries the NAS coordinates and is
provisioned out-of-band via `task k8s:<env>:nfs-pv`. The OBS *Deployment* that
mounts the `obs-music` claim is synthesized from the obs repo — a cross-repo
coupling on the claim name, like `vlc-dashcam`. obs is a public repo, which is
the other reason the coords stay on this side.
"""

from __future__ import annotations

import imports.k8s as k8s
from constructs import Construct

from adanalife_k8s.config import EnvConfig

# The music share is a few GB of audio, not a video corpus — but PVC capacity on
# a statically-bound NFS PV is a label, not a quota (the NAS enforces the real
# limit), so this only has to match between the PV and PVC to bind.
_CAPACITY = "50Gi"


def emit_music_pvc(scope: Construct, env: EnvConfig) -> None:
    """The background-music PVC — Argo-managed, emitted beside the dashcam PVC so
    the stateless OBS Deployments can churn without disturbing it. Binds 1:1 by
    name (volumeName + storageClassName "") to the cluster-scoped NFS PV that's
    provisioned out-of-band. ReadOnlyMany: every platform's OBS pod mounts the
    same share, and none of them write to it. No-op on hostPath envs (local/dev),
    where OBS falls back to the image-baked carhum beds."""
    if env.dashcam_mode != "nfs":
        return
    k8s.KubePersistentVolumeClaim(
        scope,
        "music-pvc",
        metadata=k8s.ObjectMeta(name="obs-music", namespace=env.namespace or None),
        spec=k8s.PersistentVolumeClaimSpec(
            access_modes=["ReadOnlyMany"],
            storage_class_name="",
            volume_name=env.music_pv_name,
            resources=k8s.ResourceRequirements(
                requests={"storage": k8s.Quantity.from_string(_CAPACITY)}
            ),
        ),
    )


def emit_music_pv(scope: Construct, env: EnvConfig) -> None:
    """The background-music NFS PersistentVolume — cluster-scoped, host-specific
    bootstrap infrastructure kept OUTSIDE Argo's reconcile loop, same as the
    dashcam PV it ships alongside in NfsPVChart. `task k8s:<env>:nfs-pv` synths it
    with the real coords from the gitignored cdk8s/dashcam-nfs.local.env; the
    committed golden carries the `<music export path>` placeholder. Reclaim policy
    is Retain — the album lives on the NAS, untouched by object deletion. Stage
    shares prod's export read-only but needs its own PV name (PVs bind 1:1)."""
    if env.dashcam_mode != "nfs":
        return
    k8s.KubePersistentVolume(
        scope,
        "music-pv",
        metadata=k8s.ObjectMeta(name=env.music_pv_name),
        spec=k8s.PersistentVolumeSpec(
            capacity={"storage": k8s.Quantity.from_string(_CAPACITY)},
            access_modes=["ReadOnlyMany"],
            persistent_volume_reclaim_policy="Retain",
            storage_class_name="",
            nfs=k8s.NfsVolumeSource(
                server=env.nfs_server, path=env.music_nfs_path, read_only=True
            ),
        ),
    )
