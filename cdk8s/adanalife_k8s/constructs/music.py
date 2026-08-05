"""The background-music storage primitives — the node-local PVC that OBS and
tripbot mount read-only to play an album as the stream's background audio bed,
plus the NFS PV/PVC pair the library is staged and mirrored from.

The bed plays off `obs-music-local`, a local-path volume on the minipc's T5. The
rule it exists to satisfy: nothing in the runtime stream path may depend on the
NAS being reachable, because OBS plays the bed and composites the video in one
process — so a share that stops answering blocks the render pipeline and takes
the stream off the air, not just the audio. The NAS keeps the library (that's
where `bin/stage-streambeats` writes) and the one-shot Job in MusicLocalizeChart
mirrors it onto the local volume on request.

Same split as the dashcam volumes next door: the PVCs are Argo-managed and safe
to commit (no host specifics), while the PV carries the NAS coordinates and is
provisioned out-of-band via `task k8s:<env>:nfs-pv`. The OBS and tripbot
*Deployments* that mount the `obs-music-local` claim are synthesized from the obs
and tripbot repos — a cross-repo coupling on the claim name, like
`vlc-dashcam-local`. obs is a public repo, which is the other reason the coords
stay on this side.
"""

from __future__ import annotations

import imports.k8s as k8s
from constructs import Construct

from adanalife_k8s.config import EnvConfig
from adanalife_k8s.constructs.dashcam import MINIPC_NODE

# The music share is a few GB of audio, not a video corpus — but PVC capacity on
# a statically-bound NFS PV is a label, not a quota (the NAS enforces the real
# limit), so this only has to match between the PV and PVC to bind.
_CAPACITY = "50Gi"

# The claim OBS and tripbot mount. Cross-repo contract — obs/cdk8s/obs_app.py and
# tripbot/cdk8s/adanalife_k8s/constructs/tripbot.py name it verbatim.
LOCAL_CLAIM = "obs-music-local"

# Size of the node-local music PVC. The staged library is 6.3 GB across 11 albums
# (measured 2026-08-05) and the full StreamBeats set is ~30, so ~20 GB covers the
# whole thing with room to grow — a rounding error against the T5's 1.3 TB free.
# Sized for the entire library on purpose: a two-tier "active albums on SSD, long
# tail on NFS" split would need something to define "active", and at this size
# nothing has to.
_LOCAL_CAPACITY = "20Gi"

# Resumable, idempotent, atomic mirror of the NFS music share onto the local PVC.
# Sizes are compared rather than mtimes, so an interrupted run can't leave a
# truncated track that looks complete, and each copy lands in a staging file
# outside the album tree before being renamed into place — so a re-run while the
# pods are live never exposes a partial file to the track scanner.
# POSIX shell + coreutils only, no rsync, matching the dashcam localize Job.
# `wc -c` rather than `stat -c%s`: stat's size flag is GNU-only, and a stat that
# fails yields an empty string on BOTH sides of the comparison, which reads as
# "same size" and skips the file forever. A missing file reports -1 instead, so
# absent never compares equal to present.
# ponytail: serial copy. 6.3 GB at NFS read speed is a few minutes; parallelize
# (xargs -P, as dashcam-localize does) only if the library grows enough to care.
# SRC/DST are overridable so tests/unit/test_music.py can run this against tmp
# dirs — the resume-after-truncation path is the reason this isn't a plain cp -r.
_LOCALIZE_SCRIPT = """
set -eu
SRC="${SRC:-/nfs}"
DST="${DST:-/local}"
TMP=$DST/.partial
mkdir -p "$TMP"
cd "$SRC"

fsize() {
  if [ -f "$1" ]; then
    wc -c <"$1" | tr -d ' '
  else
    echo -1
  fi
}

echo "music-localize: $(find . -type f | wc -l | tr -d ' ') file(s) on NFS -> $DST"
find . -type f -print | while read -r f; do
  if [ "$(fsize "$f")" = "$(fsize "$DST/$f")" ]; then
    continue
  fi
  echo "music-localize: $f"
  mkdir -p "$DST/$(dirname "$f")"
  cp "$f" "$TMP/staging"
  mv "$TMP/staging" "$DST/$f"
done
rmdir "$TMP" 2>/dev/null || true
echo "music-localize done: $(find "$DST" -type f | wc -l | tr -d ' ') file(s) local"
""".lstrip("\n")  # no leading blank line → cdk8s won't emit a trailing-whitespace row


def emit_music_pvc(scope: Construct, env: EnvConfig) -> None:
    """The NFS music-share PVC — Argo-managed, emitted beside the dashcam PVC so
    the stateless OBS Deployments can churn without disturbing it. Binds 1:1 by
    name (volumeName + storageClassName "") to the cluster-scoped NFS PV that's
    provisioned out-of-band. ReadOnlyMany, and no live pod mounts it: the bed
    plays off the node-local claim, and this is the staging side the localize Job
    mirrors from. No-op on hostPath envs (local/dev), where OBS falls back to the
    image-baked carhum beds."""
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


def emit_music_local_pvc(scope: Construct, env: EnvConfig) -> None:
    """The node-local music PVC — the volume the album bed actually plays from, so
    a NAS outage can't reach the stream. Argo-managed, emitted beside the NFS PVC
    it mirrors (DataChart when the DB is co-located, SupportingChart when it's
    isolated). local-path provisions on /var/mnt/data, the durable T5 UserVolume,
    which is why a `talosctl upgrade` wiping EPHEMERAL doesn't take the library
    with it.

    ReadWriteOnce because local-path is node-local. Every OBS and tripbot pod that
    mounts it is on the minipc — the only node — so same-node multi-mount is fine;
    the day there's a second node this becomes a scheduling constraint, which
    prod-stream-path-no-nas-dependency.md accepts deliberately.

    Empty until `task k8s:<env>:music-localize` fills it. Rendered on the same
    envs as the NFS pair (dashcam_mode == "nfs")."""
    if env.dashcam_mode != "nfs":
        return
    k8s.KubePersistentVolumeClaim(
        scope,
        "music-local-pvc",
        metadata=k8s.ObjectMeta(name=LOCAL_CLAIM, namespace=env.namespace or None),
        spec=k8s.PersistentVolumeClaimSpec(
            access_modes=["ReadWriteOnce"],
            storage_class_name="local-path",
            resources=k8s.ResourceRequirements(
                requests={"storage": k8s.Quantity.from_string(_LOCAL_CAPACITY)}
            ),
        ),
    )


def emit_music_localize_job(scope: Construct, env: EnvConfig) -> None:
    """One-shot Job that mirrors the NFS music share onto the node-local claim.
    Mounts the NFS export read-only + the local PVC read-write and runs a
    resumable, atomic-rename copy (see _LOCALIZE_SCRIPT).

    Kept OUTSIDE Argo — it carries the NAS coords, so it lives in its own
    dist/<env>-music-localize.k8s.yaml that no ApplicationSet globs, applied on
    demand via `task k8s:<env>:music-localize` with the real coords injected at
    synth. Run it after staging albums with `bin/stage-streambeats` (tripbot), and
    after a wipe. Re-running is cheap: files already present are skipped.

    Pinned to the minipc (where the local volume lives) at dashcam-cv-low priority
    so the bulk NAS read is preempted before the live stream ever is."""
    if env.dashcam_mode != "nfs":
        return
    q = k8s.Quantity.from_string
    k8s.KubeJob(
        scope,
        "music-localize-job",
        metadata=k8s.ObjectMeta(name="music-localize", namespace=env.namespace or None),
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
                            resources=k8s.ResourceRequirements(
                                requests={"cpu": q("100m"), "memory": q("64Mi")},
                                limits={"cpu": q("500m"), "memory": q("256Mi")},
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
                                path=env.music_nfs_path,
                                read_only=True,
                            ),
                        ),
                        k8s.Volume(
                            name="local",
                            persistent_volume_claim=k8s.PersistentVolumeClaimVolumeSource(
                                claim_name=LOCAL_CLAIM
                            ),
                        ),
                    ],
                ),
            ),
        ),
    )
