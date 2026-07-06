"""Postgres — the tripbot StatefulSet (pgvector/pg16) + headless Service.

Reproduces k8s/apps/postgres/base + overlays. The StatefulSet is the
*fidelity-critical* object here: on prod-1 it owns a 50Gi `local-path-retain`
PVC holding years of irreplaceable data (chat history since 2019, miles,
events). This construct is applied via SSA to ADOPT the live prod StatefulSet,
so the immutable join keys MUST match the live spec byte-for-byte:

  * `metadata.name` = postgres
  * `spec.serviceName` = postgres (the headless Service)
  * `spec.selector.matchLabels` = {app: postgres}
  * `spec.template.metadata.labels` = {app: postgres}
  * `spec.volumeClaimTemplates[0]` — name `postgres-data`, accessModes
    [ReadWriteOnce], and the env's storage size / storageClassName.

A mismatch on any of those would orphan the running pod or trigger a
StatefulSet replacement → data loss. The volumeClaimTemplate is threaded from
env.postgres_size / env.postgres_storage_class so prod stays 50Gi /
local-path-retain.

Per-env shape:
  * StatefulSet + headless Service everywhere.
  * postgres-secret: ESO ExternalSecret (eso envs) or a local Secret built
    from the on-disk secret.env placeholders (local laptop overlay).
  * prod-1 only (env.postgres_backup): a local-path-retain StorageClass, a
    daily backup CronJob, and the postgres-backup-s3 ExternalSecret.
"""

from __future__ import annotations

import cdk8s
import imports.k8s as k8s
from constructs import Construct

from adanalife_k8s.config import EnvConfig
from adanalife_k8s.naming import meta_labels, selector

NAME = "postgres"
SECRET_NAME = "postgres-secret"  # materialized Secret the StatefulSet envFroms
PORT = 5432

# SSM parameter paths (terraform-owned values; the SM names with a leading
# slash since the SM → SSM migration). See base/external-secret.yaml.
_CREDS_SM = "/k8s/postgres/credentials"
_BACKUP_SM = "/k8s/postgres/backup-s3-credentials"

# Placeholder DB creds for the laptop `local` overlay (gitignored secret.env in
# Kustomize). Match tripbot/infra/docker/env.docker and the local render.
_LOCAL_SECRET = {
    "POSTGRES_USER": "tripbot_docker",
    "POSTGRES_PASSWORD": "hunter2",
    "POSTGRES_DB": "tripbot_docker",
}

# The backup CronJob's dump-and-upload script. frame_embeddings data is
# excluded: the vectors are derived + reproducible (re-runnable batch embed,
# dedicated dump via `task tripbot:stage:db:backup:vectors`) and would bloat
# every tiered dump by GBs. The table definition still ships (schema, not
# data), so a restore leaves an empty table for migrations/seed to fill.
_BACKUP_SCRIPT = """\
set -euo pipefail
apk add --no-cache aws-cli
TS=$(date -u +%Y%m%d-%H%M%SZ)
HOUR=$(date -u +%H)
DOW=$(date -u +%u)   # 1=Mon ... 7=Sun
DUMP=/tmp/dump.pgcustom

echo "Dumping ${POSTGRES_DB}"
PGPASSWORD="$POSTGRES_PASSWORD" pg_dump \\
  --format=custom \\
  --host=postgres \\
  --username="$POSTGRES_USER" \\
  --exclude-table-data=frame_embeddings \\
  "$POSTGRES_DB" \\
  > "$DUMP"

echo "Uploading hourly/${TS}.dump"
aws s3 cp --no-progress "$DUMP" "s3://${S3_BUCKET}/hourly/${TS}.dump"

if [ "$HOUR" = "04" ]; then
  echo "Uploading daily/${TS}.dump"
  aws s3 cp --no-progress "$DUMP" "s3://${S3_BUCKET}/daily/${TS}.dump"
fi

if [ "$HOUR" = "04" ] && [ "$DOW" = "7" ]; then
  echo "Uploading weekly/${TS}.dump"
  aws s3 cp --no-progress "$DUMP" "s3://${S3_BUCKET}/weekly/${TS}.dump"
fi

rm -f "$DUMP"
echo "OK"
"""


class Postgres(Construct):
    def __init__(self, scope: Construct, *, env: EnvConfig):
        super().__init__(scope, NAME)
        # postgres lives in the data namespace — the app namespace by default
        # (parity), or an isolated one (env.data_namespace). The backup CronJob
        # rides along here, so its --host=postgres stays a same-namespace lookup.
        ns = env.data_ns or None
        labels = meta_labels(NAME)
        sel = selector(NAME)

        # --- postgres-secret: ESO ExternalSecret | local on-disk Secret ---
        # The Secret NAME stays stable (postgres-secret) in both cases — the
        # StatefulSet/CronJob envFrom references it by that name.
        if env.secret_source == "local":
            k8s.KubeSecret(
                self,
                "secret",
                metadata=k8s.ObjectMeta(name=SECRET_NAME, namespace=ns),
                type="Opaque",
                string_data=dict(_LOCAL_SECRET),
            )
        else:
            # ESO maps the SM JSON {user,password,db} onto POSTGRES_* keys via
            # target.template — a shape the eso.external_secret helper doesn't
            # cover, so (like obs.py's stream-key) emit it as a raw ApiObject.
            self._external_secret(
                "credentials",
                "postgres-credentials",
                ns,
                labels,
                target=SECRET_NAME,
                data=[
                    ("user", _CREDS_SM, "user"),
                    ("password", _CREDS_SM, "password"),
                    ("db", _CREDS_SM, "db"),
                ],
                template={
                    "POSTGRES_USER": "{{ .user }}",
                    "POSTGRES_PASSWORD": "{{ .password }}",
                    "POSTGRES_DB": "{{ .db }}",
                },
            )

        # --- container ---
        container = k8s.Container(
            name=NAME,
            # GHCR mirror, not Docker Hub — a cold dev (k3d) bringup pulled this
            # node-side from Hub in ~10min under the account-wide rate limit
            # (stage/prod cache it once so they never feel it; ephemeral dev eats
            # it every bringup). The mirror is the weekly-refreshed copy from the
            # ghcr-base-image-mirrors decision; GHCR isn't rate-limited.
            image="ghcr.io/adanalife/mirror/pgvector:pg16",
            security_context=k8s.SecurityContext(
                allow_privilege_escalation=False,
                capabilities=k8s.Capabilities(drop=["ALL"]),
            ),
            ports=[k8s.ContainerPort(name="postgres", container_port=PORT)],
            env_from=[
                k8s.EnvFromSource(secret_ref=k8s.SecretEnvSource(name=SECRET_NAME))
            ],
            # pg_isready answers protocol-level — catches "up but not serving".
            liveness_probe=k8s.Probe(
                exec=k8s.ExecAction(command=["pg_isready", "-U", "$(POSTGRES_USER)"]),
                initial_delay_seconds=10,
                period_seconds=30,
                timeout_seconds=5,
                failure_threshold=3,
            ),
            readiness_probe=k8s.Probe(
                tcp_socket=k8s.TcpSocketAction(
                    port=k8s.IntOrString.from_string("postgres")
                ),
                initial_delay_seconds=5,
                period_seconds=5,
            ),
            resources=k8s.ResourceRequirements(
                requests={
                    "cpu": k8s.Quantity.from_string("100m"),
                    "memory": k8s.Quantity.from_string("256Mi"),
                },
                # 1Gi was too low: the bulk HNSW index build on a
                # frame_embeddings restore OOM-killed prod at 1Gi and lost the
                # PVC (2026-06-15). The seed:vectors task now forces a bounded
                # on-disk build so it fits, but give headroom on the SSD-backed
                # minipc so a faster in-memory build is an option and steady
                # state has breathing room.
                limits={"memory": k8s.Quantity.from_string("2Gi")},
            ),
            volume_mounts=[
                k8s.VolumeMount(
                    name="postgres-data",
                    mount_path="/var/lib/postgresql/data",
                    sub_path="pgdata",
                )
            ],
        )

        # --- volumeClaimTemplate (the SSA-adoption-critical bit) ---
        vct_spec = k8s.PersistentVolumeClaimSpec(
            access_modes=["ReadWriteOnce"],
            resources=k8s.ResourceRequirements(
                requests={"storage": k8s.Quantity.from_string(env.postgres_size)}
            ),
            # "" → omit entirely (cluster default), matching the dev/local render.
            storage_class_name=env.postgres_storage_class or None,
        )

        # --- StatefulSet ---
        k8s.KubeStatefulSet(
            self,
            "statefulset",
            metadata=k8s.ObjectMeta(name=NAME, namespace=ns, labels=labels),
            spec=k8s.StatefulSetSpec(
                service_name=NAME,
                replicas=1,
                selector=k8s.LabelSelector(match_labels=sel),
                template=k8s.PodTemplateSpec(
                    metadata=k8s.ObjectMeta(labels=sel),
                    spec=k8s.PodSpec(
                        # PSA `restricted`: non-root (uid/gid 999 = postgres in
                        # the pgvector/pg16 Debian image — NOT 70, that's Alpine),
                        # seccomp RuntimeDefault, no-privesc + caps drop[ALL] on
                        # the container. fsGroup 999 has the kubelet group-own the
                        # volume at mount so postgres writes PGDATA without the
                        # image's first-boot root chown (the reason this was
                        # previously deferred). Safe only on a fresh/empty PVC — an
                        # existing large volume would pay a slow recursive chown.
                        # Validated on prod's first boot on the new T5 UserVolume.
                        security_context=k8s.PodSecurityContext(
                            run_as_non_root=True,
                            run_as_user=999,
                            run_as_group=999,
                            fs_group=999,
                            seccomp_profile=k8s.SeccompProfile(type="RuntimeDefault"),
                        ),
                        containers=[container],
                    ),
                ),
                volume_claim_templates=[
                    k8s.KubePersistentVolumeClaimProps(
                        metadata=k8s.ObjectMeta(name="postgres-data"), spec=vct_spec
                    )
                ],
            ),
        )

        # --- headless Service (clusterIP: None) — the StatefulSet's serviceName ---
        k8s.KubeService(
            self,
            "service",
            metadata=k8s.ObjectMeta(name=NAME, namespace=ns, labels=labels),
            spec=k8s.ServiceSpec(
                cluster_ip="None",
                selector=sel,
                ports=[
                    k8s.ServicePort(
                        name="postgres",
                        port=PORT,
                        target_port=k8s.IntOrString.from_string("postgres"),
                    )
                ],
            ),
        )

        # --- prod-only: backup StorageClass + CronJob + S3 ExternalSecret ---
        if env.postgres_backup:
            self._storage_class()
            self._backup_external_secret(ns)
            self._backup_cronjob(ns)

    # ---- helpers ----
    def _storage_class(self):
        # Retain reclaim policy: the safety lever so `kubectl delete pvc` (or a
        # re-deploy that recreates the PVC) leaves the underlying disk intact.
        k8s.KubeStorageClass(
            self,
            "storageclass",
            metadata=k8s.ObjectMeta(name="local-path-retain"),
            provisioner="rancher.io/local-path",
            reclaim_policy="Retain",
            volume_binding_mode="WaitForFirstConsumer",
            allow_volume_expansion=False,
        )

    def _backup_external_secret(self, ns):
        # No metadata labels — this overlay-only resource isn't covered by the
        # base kustomization's `labels:` directive (matches the render).
        self._external_secret(
            "backup-credentials",
            "postgres-backup-s3-credentials",
            ns,
            None,
            target="postgres-backup-s3",
            data=[
                ("AWS_ACCESS_KEY_ID", _BACKUP_SM, "AWS_ACCESS_KEY_ID"),
                ("AWS_SECRET_ACCESS_KEY", _BACKUP_SM, "AWS_SECRET_ACCESS_KEY"),
                ("AWS_DEFAULT_REGION", _BACKUP_SM, "AWS_DEFAULT_REGION"),
                ("S3_BUCKET", _BACKUP_SM, "S3_BUCKET"),
            ],
            template={
                "AWS_ACCESS_KEY_ID": "{{ .AWS_ACCESS_KEY_ID }}",
                "AWS_SECRET_ACCESS_KEY": "{{ .AWS_SECRET_ACCESS_KEY }}",
                "AWS_DEFAULT_REGION": "{{ .AWS_DEFAULT_REGION }}",
                "S3_BUCKET": "{{ .S3_BUCKET }}",
            },
        )

    def _external_secret(self, id, name, ns, labels, *, target, data, template):
        # ExternalSecret with a target.template that remaps SM JSON properties
        # onto the materialized Secret's keys. ESO CRD isn't in imports/k8s, so
        # emit via ApiObject + a /spec JSON patch (same idiom as obs.py / eso.py).
        meta: dict = {"name": name}
        if ns:
            meta["namespace"] = ns
        if labels:
            meta["labels"] = labels
        es = cdk8s.ApiObject(
            self,
            id,
            api_version="external-secrets.io/v1",
            kind="ExternalSecret",
            metadata=meta,
        )
        es.add_json_patch(
            cdk8s.JsonPatch.add(
                "/spec",
                {
                    "refreshInterval": "1h",
                    "secretStoreRef": {
                        "name": "aws-parameterstore",
                        "kind": "SecretStore",
                    },
                    "target": {
                        "name": target,
                        "template": {"type": "Opaque", "data": template},
                    },
                    "data": [
                        {"secretKey": sk, "remoteRef": {"key": k, "property": p}}
                        for sk, k, p in data
                    ],
                },
            )
        )

    def _backup_cronjob(self, ns):
        backup = k8s.Container(
            name="backup",
            image="postgres:16-alpine",  # PG16 pg_dump, matches the server image
            command=["/bin/sh", "-c"],
            args=[_BACKUP_SCRIPT],
            env_from=[
                k8s.EnvFromSource(secret_ref=k8s.SecretEnvSource(name=SECRET_NAME)),
                k8s.EnvFromSource(
                    secret_ref=k8s.SecretEnvSource(name="postgres-backup-s3")
                ),
            ],
            resources=k8s.ResourceRequirements(
                requests={
                    "cpu": k8s.Quantity.from_string("100m"),
                    "memory": k8s.Quantity.from_string("128Mi"),
                },
                limits={"memory": k8s.Quantity.from_string("512Mi")},
            ),
        )
        k8s.KubeCronJob(
            self,
            "backup",
            metadata=k8s.ObjectMeta(name="postgres-backup", namespace=ns),
            spec=k8s.CronJobSpec(
                schedule="0 * * * *",
                suspend=False,
                time_zone="Etc/UTC",
                concurrency_policy="Forbid",
                successful_jobs_history_limit=3,
                failed_jobs_history_limit=3,
                job_template=k8s.JobTemplateSpec(
                    spec=k8s.JobSpec(
                        backoff_limit=1,
                        ttl_seconds_after_finished=604800,
                        template=k8s.PodTemplateSpec(
                            spec=k8s.PodSpec(
                                restart_policy="Never", containers=[backup]
                            )
                        ),
                    )
                ),
            ),
        )
