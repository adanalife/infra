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

# The album track index and the ConfigMap it travels in. tripbot mounts this
# instead of the claim — it lists the library to shuffle and advance tracks but
# never opens a track, and a ConfigMap volume can be optional where a PVC volume
# cannot (an unbound claim would hold every tripbot Deployment unschedulable over
# a bed nobody is listening to). Four-way name contract: tripbot's
# constructs/tripbot.py MUSIC_INDEX_CONFIGMAP, pkg/obs/beds.MusicIndexFile, and
# tripbot's bin/stage-streambeats, which writes the same file from a Mac with the
# share mounted. The paths inside it are where OBS sees the tracks, which is why
# POD_MUSIC_DIR has to match tripbot's MUSIC_MOUNT_PATH and beds.MusicDir exactly.
INDEX_CONFIGMAP = "obs-music-index"
INDEX_KEY = "index.json"
POD_MUSIC_DIR = "/opt/tripbot/assets/music"

# Where the localize step hands the rendered ConfigMap to the step that applies
# it. An emptyDir between an initContainer and the container proper, because the
# two need different images and only one of them has a shell.
_HANDOFF_DIR = "/handoff"
_HANDOFF_FILE = f"{_HANDOFF_DIR}/{INDEX_CONFIGMAP}.yaml"

# kubectl from the Kubernetes project's own registry, pinned to the cluster's
# minor. Not a ghcr mirror: ghcr-base-image-mirrors.md exists because Docker Hub
# rate-limits CI pulls, and registry.k8s.io is neither Docker Hub nor CI — it is
# unauthenticated and unmetered, so mirroring it would buy a manual refresh
# chore and nothing else. Distroless, so `kubectl` is the entrypoint and there is
# no shell to pipe through — the manifest arrives ready to apply.
_KUBECTL_IMAGE = "registry.k8s.io/kubectl:v1.36.0"

# ServiceAccount, Role and RoleBinding all share this name — there is exactly one
# of each and they only ever refer to one another.
_SA = "music-localize"

# The audio extensions an album track can have. Same set as tripbot's
# bin/stage-streambeats AUDIO_EXTS, and the reason the Synology `@eaDir` sidecar
# files (`... .mp3@SynoEAStream`) never reach the index: they end in neither.
_AUDIO_EXTS = ("mp3", "flac", "m4a", "ogg")

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
_LOCALIZE_SCRIPT = r"""
set -eu
SRC="${SRC:-/nfs}"
DST="${DST:-/local}"
# OUT/CM/KEY/POD carry no defaults on purpose: they come from the container env
# so the Python constants stay the single source of the names, and `set -u` turns
# a cdk8s change that drops one into a failed Job rather than a moved index.
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

# The album index, rendered as a whole ConfigMap manifest for the kubectl step.
# Built from $DST rather than $SRC so it can only ever name tracks that are
# already local: an interrupted mirror yields a short index, never an entry that
# resolves to nothing when the bed tries to play it. Rebuilt from scratch each
# run, so an album deleted from the share leaves the index on the next one.
# No namespace on the object — kubectl in-cluster defaults to the pod's own,
# which is the one the tripbot Deployments read it from.
echo "music-index: writing $OUT"
{
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\ndata:\n  %s: |\n' "$CM" "$KEY"
  cd "$DST"
  find . -type f \( -name '*.mp3' -o -name '*.flac' -o -name '*.m4a' -o -name '*.ogg' \) |
    sed 's|^\./||' |
    grep / |
    LC_ALL=C sort |
    awk -v pod="$POD" '
      function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
      BEGIN { print "{" }
      {
        a = $0; sub(/\/.*/, "", a)
        if (a != album) {
          if (album != "") printf "\n  ],\n"
          printf "  \"%s\": [", esc(a)
          album = a; first = 1
        }
        printf "%s\n    \"%s/%s\"", (first ? "" : ","), pod, esc($0)
        first = 0
      }
      END { if (album != "") printf "\n  ]\n"; print "}" }
    ' |
    sed 's/^/    /'
} >"$OUT"
echo "music-index: $(grep -c '^        "' "$OUT") track(s) indexed"
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


def emit_music_index_rbac(scope: Construct, env: EnvConfig) -> None:
    """The identity the localize Job publishes the index under.

    Scoped to one ConfigMap by name, and to the verbs `kubectl apply` needs to
    create it once and patch it after: this Job runs on the same node as the live
    stream, so the smallest credential that does the job is the one worth having.
    No `delete` and no `list` — nothing here should be able to remove the index
    the bed is playing off, and a Role that can't enumerate can't be borrowed to
    read the namespace's other ConfigMaps."""
    if env.dashcam_mode != "nfs":
        return
    ns = env.namespace or None
    k8s.KubeServiceAccount(
        scope, "music-localize-sa", metadata=k8s.ObjectMeta(name=_SA, namespace=ns)
    )
    k8s.KubeRole(
        scope,
        "music-localize-role",
        metadata=k8s.ObjectMeta(name=_SA, namespace=ns),
        rules=[
            k8s.PolicyRule(
                api_groups=[""],
                resources=["configmaps"],
                resource_names=[INDEX_CONFIGMAP],
                verbs=["get", "patch", "update"],
            ),
            # `create` cannot be narrowed by resourceName — the object does not
            # exist yet, so there is nothing for the authorizer to match on. It is
            # the one verb here that covers the whole namespace, which is why the
            # rest are split out rather than folded into a single rule.
            k8s.PolicyRule(api_groups=[""], resources=["configmaps"], verbs=["create"]),
        ],
    )
    k8s.KubeRoleBinding(
        scope,
        "music-localize-rolebinding",
        metadata=k8s.ObjectMeta(name=_SA, namespace=ns),
        role_ref=k8s.RoleRef(
            api_group="rbac.authorization.k8s.io", kind="Role", name=_SA
        ),
        subjects=[
            k8s.Subject(kind="ServiceAccount", name=_SA, namespace=env.namespace)
        ],
    )


def emit_music_localize_job(scope: Construct, env: EnvConfig) -> None:
    """One-shot Job that mirrors the NFS music share onto the node-local claim and
    publishes the album index describing what landed.

    Two steps, because they need different images and only one needs a shell: an
    initContainer mounts the NFS export read-only + the local PVC read-write and
    runs the resumable, atomic-rename copy (see _LOCALIZE_SCRIPT), leaving a
    rendered ConfigMap manifest on a shared emptyDir; the container proper is
    distroless kubectl and applies it. Running them in that order is the point —
    the index is written from the local volume after the copy, so it can only
    describe tracks that are really there, and the copy and the index can no
    longer drift apart the way they did when the index was a manual step
    (2026-09-08: seven hours of dead air on both prod platforms, because the
    ConfigMap had never been created at all).

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
    small = k8s.ResourceRequirements(
        requests={"cpu": q("100m"), "memory": q("64Mi")},
        limits={"cpu": q("500m"), "memory": q("256Mi")},
    )
    handoff = k8s.VolumeMount(name="handoff", mount_path=_HANDOFF_DIR)
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
                    service_account_name=_SA,
                    init_containers=[
                        k8s.Container(
                            name="localize",
                            image="ghcr.io/adanalife/mirror/ubuntu:24.04",
                            command=["sh", "-c", _LOCALIZE_SCRIPT],
                            # The names the script writes into the manifest live in
                            # Python, not the shell, so this file stays the one
                            # place they are spelled.
                            env=[
                                k8s.EnvVar(name="OUT", value=_HANDOFF_FILE),
                                k8s.EnvVar(name="CM", value=INDEX_CONFIGMAP),
                                k8s.EnvVar(name="KEY", value=INDEX_KEY),
                                k8s.EnvVar(name="POD", value=POD_MUSIC_DIR),
                            ],
                            resources=small,
                            volume_mounts=[
                                k8s.VolumeMount(
                                    name="nfs", mount_path="/nfs", read_only=True
                                ),
                                k8s.VolumeMount(name="local", mount_path="/local"),
                                handoff,
                            ],
                        )
                    ],
                    containers=[
                        k8s.Container(
                            name="publish-index",
                            image=_KUBECTL_IMAGE,
                            args=["apply", "-f", _HANDOFF_FILE],
                            resources=small,
                            volume_mounts=[handoff],
                        )
                    ],
                    volumes=[
                        k8s.Volume(
                            name="handoff", empty_dir=k8s.EmptyDirVolumeSource()
                        ),
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
