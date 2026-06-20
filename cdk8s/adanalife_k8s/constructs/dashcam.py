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


# The local-path corpus cache, the live vlc pods, and the copy Job all pin to this
# node: local-path is node-local, and the minipc is the only node with the iGPU and
# the NAS reach the stream needs.
MINIPC_NODE = "adanalife-minipc"

# Parallel copy streams for the localize Job. A single NFS read tops out ~25 MB/s
# (measured), well under the NAS aggregate, so a handful of streams multiplex past
# it. This is the dial to lower if the bulk read starts competing with the live
# stream's NAS reads (the 2026-06-15 contention failure mode).
LOCALIZE_WORKERS = 8

# Resumable, idempotent, atomic parallel copy of the NFS corpus onto the local PVC.
# Each clip is copied to a `.partial` temp then renamed, so an interrupted run never
# leaves a truncated file that looks done; a size check skips clips already fully
# present, so re-running after an interrupt (or to top up new clips) only does the
# remaining work. Coreutils + GNU find only — no rsync, so the mirrored ubuntu base
# needs nothing installed at runtime.
_LOCALIZE_SCRIPT = """
set -eu
SRC=/nfs
DST=/local
mkdir -p "$DST"
total=$(find "$SRC" -maxdepth 1 -type f -name '*.MP4' | wc -l)
echo "dashcam-localize: $total clip(s) on NFS -> $DST (workers=$WORKERS)"
find "$SRC" -maxdepth 1 -type f -name '*.MP4' -printf '%f\\n' | xargs -P "$WORKERS" -I{} sh -c '
  f="$1"
  src="/nfs/$f"
  dst="/local/$f"
  if [ -f "$dst" ] && [ "$(stat -c%s "$src")" = "$(stat -c%s "$dst")" ]; then exit 0; fi
  cp "$src" "/local/.$f.partial" && mv "/local/.$f.partial" "$dst"
' _ {}
echo "dashcam-localize done: $(find "$DST" -maxdepth 1 -type f -name '*.MP4' | wc -l) clip(s) local"
"""


def emit_dashcam_local_pvc(scope: Construct, env: EnvConfig) -> None:
    """The node-local dashcam corpus PVC — a local-path cache of the NFS _opt/clips
    corpus so vlc can serve the stream off local NVMe. Argo-managed (lives with the
    NFS PVC: DataChart when co-located, SupportingChart when the DB is isolated),
    prune-only-on-deliberate-disable. ReadWriteOnce because local-path is node-local;
    every vlc pod is co-located on the minipc, so same-node multi-mount is fine.
    local-path is WaitForFirstConsumer, so the volume consumes zero disk until the
    copy Job (or vlc) first mounts it. No-op (golden render unchanged) until an env
    sets dashcam_local_enabled."""
    if not env.dashcam_local_enabled:
        return
    ns = env.namespace or None
    k8s.KubePersistentVolumeClaim(
        scope,
        "dashcam-local-pvc",
        metadata=k8s.ObjectMeta(name="vlc-dashcam-local", namespace=ns),
        spec=k8s.PersistentVolumeClaimSpec(
            access_modes=["ReadWriteOnce"],
            storage_class_name="local-path",
            resources=k8s.ResourceRequirements(
                requests={"storage": k8s.Quantity.from_string(env.dashcam_local_size)}
            ),
        ),
    )


def emit_dashcam_localize_job(scope: Construct, env: EnvConfig) -> None:
    """One-shot Job that copies the NFS _opt/clips corpus onto the node-local
    `vlc-dashcam-local` PVC. Mounts the NFS export read-only + the local PVC
    read-write and runs a parallel, resumable, atomic-rename copy (see
    _LOCALIZE_SCRIPT). Kept OUTSIDE Argo (its own dist/<env>-dashcam-localize.k8s.yaml,
    globbed by no ApplicationSet — same as the NFS PV), applied on demand via
    `task k8s:<env>:dashcam-localize` with the real NFS coords injected at synth.
    Pinned to the minipc (the local-path node) at dashcam-cv-low priority so the bulk
    NAS read is preempted before the live stream ever is. No-op until
    dashcam_local_enabled."""
    if not env.dashcam_local_enabled:
        return
    q = k8s.Quantity.from_string
    k8s.KubeJob(
        scope,
        "dashcam-localize-job",
        metadata=k8s.ObjectMeta(
            name="dashcam-localize", namespace=env.namespace or None
        ),
        spec=k8s.JobSpec(
            backoff_limit=4,
            template=k8s.PodTemplateSpec(
                spec=k8s.PodSpec(
                    restart_policy="Never",
                    priority_class_name="dashcam-cv-low",
                    node_selector={"kubernetes.io/hostname": MINIPC_NODE},
                    containers=[
                        k8s.Container(
                            name="localize",
                            image="ghcr.io/adanalife/mirror/ubuntu:24.04",
                            command=["sh", "-c", _LOCALIZE_SCRIPT],
                            env=[
                                k8s.EnvVar(name="WORKERS", value=str(LOCALIZE_WORKERS))
                            ],
                            resources=k8s.ResourceRequirements(
                                requests={"cpu": q("500m"), "memory": q("256Mi")},
                                limits={"cpu": q("1"), "memory": q("512Mi")},
                            ),
                            volume_mounts=[
                                k8s.VolumeMount(
                                    name="nfs", mount_path="/nfs", read_only=True
                                ),
                                k8s.VolumeMount(name="local", mount_path="/local"),
                            ],
                        )
                    ],
                    volumes=[
                        k8s.Volume(
                            name="nfs",
                            nfs=k8s.NfsVolumeSource(
                                server=env.nfs_server,
                                path=env.nfs_path,
                                read_only=True,
                            ),
                        ),
                        k8s.Volume(
                            name="local",
                            persistent_volume_claim=k8s.PersistentVolumeClaimVolumeSource(
                                claim_name="vlc-dashcam-local"
                            ),
                        ),
                    ],
                ),
            ),
        ),
    )
