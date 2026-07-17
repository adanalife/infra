"""Per-environment configuration — the matrix knobs the Kustomize overlays vary.

One `EnvConfig` replaces the per-app `overlays/<env>` sprawl. Charts/constructs
read these fields instead of branching on env name inline. App-specific config
that *also* varies by env (the big vlc/tripbot literal blocks) is assembled in
each construct from these knobs; this table holds only the cross-app values.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class EnvConfig:
    name: str  # prod-1 | stage-1 | development | local
    namespace: str
    cluster: str  # minipc | k3d | local
    dns_base: str  # prod.whereisdana.today | stage... | dev...  ("" for local)
    secret_source: str = "eso"  # eso | local
    dashcam_mode: str = "hostpath"  # nfs | hostpath
    tailscale: bool = False  # emit the tailscale Ingress
    postgres_size: str = "5Gi"
    postgres_storage_class: str = ""  # "" = cluster default; local-path-retain on prod
    postgres_backup: bool = False
    # "" → postgres co-locates in the app namespace (default, byte-identical
    # render). Set to an isolated namespace (e.g. "stage-1-data") to move the DB
    # StatefulSet + its ESO SecretStore out of the app namespace, so deleting the
    # app namespace can't drop the database. Apps reach it cross-namespace via the
    # postgres_host FQDN. The dashcam PVC does NOT move (vlc mounts it; PVCs are
    # namespace-local) — it shifts to SupportingChart in the app namespace.
    data_namespace: str = ""
    external_dns_role_arn: str = (
        ""  # cert-manager DNS-01 Route53 role (per AWS account)
    )
    lan_ip: str = (
        "192.168.1.200"  # mini-PC node IP external-dns/traefik target (platform Helm)
    )
    nfs_server: str = ""  # dashcam NFS export (nfs mode); from $NFS_SERVER at synth
    nfs_path: str = ""  # dashcam NFS path; from the $nfs_path_env var at synth
    # Which env var supplies this env's dashcam path. Both nfs envs now read the
    # shared $NFS_PATH, which points at the canonical regenerated _opt/clips
    # corpus (smaller, +faststart, fixes the corrupt airing clips). The override
    # mechanism stays generic — it let stage stream _opt while prod stayed on the
    # airing _all export during the regen — but no env diverges today. Falls back
    # to $NFS_PATH when an override is unset, so the golden render is unchanged.
    nfs_path_env: str = "NFS_PATH"
    nfs_pv_name: str = (
        "vlc-dashcam-nfs"  # PVs bind 1:1 — stage needs its own (vlc-dashcam-nfs-stage)
    )
    # --- node-local dashcam corpus (the NFS<->local serving toggle) -------------
    # When True, a node-local `vlc-dashcam-local` PVC (local-path, on the minipc)
    # is emitted beside the NFS PVC, and the one-shot copy Job (DashcamLocalizeChart)
    # is rendered. It's the durable corpus *cache* — vlc can serve the stream off
    # local NVMe instead of the NAS. The cache persists across the mount flip, so
    # toggling vlc back to NFS never discards it; the NFS PVC always stays defined
    # as the instant fallback while the local copy is (re)populated. Which source
    # vlc actually mounts is the tripbot repo's `dashcam_source` flag — this flag
    # only governs whether the local PVC + copy Job exist. Off by default (golden
    # render unchanged). To adopt local serving on an env: flip this on, apply, run
    # `task k8s:<env>:dashcam-localize`, then point vlc at it (dashcam_source=local).
    dashcam_local_enabled: bool = False
    # Size of the node-local corpus PVC. The regenerated _opt/clips corpus is
    # ~630 GB; this leaves headroom without crowding the other local-path PVCs.
    dashcam_local_size: str = "700Gi"
    # Streaming platforms present in this env (obs instances). twitch everywhere;
    # youtube currently stage-only while the bot side is built out.
    platforms: tuple[str, ...] = ("twitch",)

    @property
    def tls(self) -> bool:
        """Whether app ingresses get cert-manager TLS (minipc envs only)."""
        return self.cluster == "minipc"

    @property
    def data_ns(self) -> str:
        """Namespace the stateful data unit (postgres + its SecretStore) lands in:
        the app namespace by default, or the isolated one when data_namespace set."""
        return self.data_namespace or self.namespace

    @property
    def data_isolated(self) -> bool:
        """True when postgres lives in its own namespace, split from the app ns."""
        return bool(self.data_namespace) and self.data_namespace != self.namespace

    @property
    def postgres_host(self) -> str:
        """DATABASE_HOST apps connect to: the bare Service name when co-located
        (parity), the cross-namespace FQDN when the DB is isolated."""
        return (
            f"postgres.{self.data_namespace}.svc.cluster.local"
            if self.data_isolated
            else "postgres"
        )


# Stage and dev share the adanalife-stage account → same ExternalDNSRole ARN.
_STAGE_ROLE = "arn:aws:iam::413585268653:role/ExternalDNSRole"
_PROD_ROLE = "arn:aws:iam::704461573429:role/ExternalDNSRole"


# Per-env table. Mirrors the Kustomize overlays; the source of truth once those
# overlays are retired. Values cross-checked against k8s/apps/*/overlays/<env>.
ENVS: dict[str, EnvConfig] = {
    "prod-1": EnvConfig(
        name="prod-1",
        namespace="prod-1",
        cluster="minipc",
        dashcam_local_enabled=True,  # serve the corpus off the minipc's local NVMe
        dns_base="prod.whereisdana.today",
        dashcam_mode="nfs",
        tailscale=True,
        postgres_size="50Gi",
        postgres_storage_class="local-path-retain",
        postgres_backup=True,
        external_dns_role_arn=_PROD_ROLE,
        # Streams the shared $NFS_PATH — now the canonical regenerated _opt/clips
        # corpus, cut over from the airing _all export once the regen completed.
        nfs_pv_name="vlc-dashcam-nfs",
        # The DB lives in its own namespace so a `kubectl delete ns prod-1` can't
        # take years of irreplaceable data.
        data_namespace="prod-1-data",
        # youtube is staged here so Argo creates the prod-youtube Applications,
        # but the tripbot repo renders that stack at replicas=0 (parked_platforms)
        # until stage-youtube is shut down and prod-youtube is turned on — the
        # minipc never runs two youtube stacks at once. This list is the Argo
        # fan-out contract; it must match the platforms tripbot's cdk8s emits.
        platforms=("twitch", "youtube"),
    ),
    "stage-1": EnvConfig(
        name="stage-1",
        namespace="stage-1",
        cluster="minipc",
        dns_base="stage.whereisdana.today",
        dashcam_mode="nfs",
        tailscale=True,
        postgres_size="10Gi",
        postgres_storage_class="local-path",
        external_dns_role_arn=_STAGE_ROLE,
        nfs_pv_name="vlc-dashcam-nfs-stage",
        # Stage reads the shared $NFS_PATH (= the canonical _opt/clips corpus),
        # same as prod — the corpus regen is complete, so the temporary
        # STAGE_NFS_PATH override that let stage run ahead on the in-progress
        # corpus has collapsed. Stage keeps its own PV name (PVs bind 1:1).
        # Stage rehearses DB-in-its-own-namespace: postgres + its SecretStore land
        # in stage-1-data, so a `kubectl delete ns stage-1` can't take the DB. prod
        # follows on its next wipe (set prod-1's data_namespace to prod-1-data).
        data_namespace="stage-1-data",
        # This list is the Argo/mediamtx fan-out for stage: every platform
        # here gets a mediamtx relay + an obs Application. facebook is the
        # active burn-in platform (streaming to the ADL Staging Page);
        # youtube/twitch stay listed so their Applications keep existing —
        # their app repos declare them parked at replicas:0.
        platforms=("youtube", "twitch", "facebook"),
    ),
    "development": EnvConfig(
        name="development",
        namespace="development",
        cluster="k3d",
        dns_base="dev.whereisdana.today",
        dashcam_mode="hostpath",
        tailscale=False,
        external_dns_role_arn=_STAGE_ROLE,
        platforms=("twitch",),
    ),
    "local": EnvConfig(
        name="local",
        namespace="default",
        cluster="local",
        dns_base="",
        secret_source="local",
        dashcam_mode="hostpath",
        tailscale=False,
        platforms=("twitch",),
    ),
}


def load_env(name: str) -> EnvConfig:
    try:
        env = ENVS[name]
    except KeyError:
        raise SystemExit(f"unknown env {name!r}; known: {', '.join(ENVS)}")
    from dataclasses import replace

    # NFS coordinates are deployment-host-specific (gitignored in Kustomize as
    # dashcam-nfs.local.yaml); thread them in from the environment at synth so
    # they never get committed. Placeholders match the legacy .example render.
    if env.dashcam_mode == "nfs":
        # Each env reads its own path var, falling back to the shared $NFS_PATH
        # (now the canonical regenerated _opt/clips corpus) — so an unset override
        # renders identically to before (and the committed golden keeps the
        # placeholder). No env overrides today; the mechanism stays for the next
        # time one env needs to run ahead of another on a fresh corpus.
        nfs_path = os.environ.get(env.nfs_path_env) or os.environ.get(
            "NFS_PATH", "<export path>"
        )
        env = replace(
            env,
            nfs_server=os.environ.get("NFS_SERVER", "<NFS server address>"),
            nfs_path=nfs_path,
        )
    return env
