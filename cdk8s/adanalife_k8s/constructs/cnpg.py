"""CNPG `pg` cluster — PITR-capable Postgres (CloudNativePG + barman-cloud).

The declarative replacement for the hand-rolled `postgres` StatefulSet: a
single-instance CNPG Cluster per env with continuous WAL archiving + daily
base backups to a dedicated S3 bucket via the barman-cloud plugin. RPO is
bounded by `archive_timeout` (5min); disaster recovery is a recovery-bootstrap
manifest against the ObjectStore, not a dump restore. HA is a non-goal —
one node, so `instances: 1`; the win is PITR.

Runs SIDE-BY-SIDE with the legacy StatefulSet during migration (no name
collision: cluster `pg` → services `pg-rw`/`pg-ro`). Data arrives via CNPG's
native logical import (`bootstrap.initdb.import`, microservice) from the
legacy `postgres` Service — a one-shot pg_dump/restore at bootstrap that
carries every table, `frame_embeddings` included (the hourly dump CronJob
excludes it). Apps must be scaled to 0 during the bootstrap window; rollback
at any point is repointing DATABASE_HOST back at `postgres`, whose PVC is
untouched.

Emitted only where `env.cnpg` is on (stage-1 first; prod-1 after the stage
PITR restore drill passes). Objects:

  * ExternalSecret `pg-app-creds` — the same SSM credentials the legacy
    Secret renders, re-shaped as `kubernetes.io/basic-auth` (CNPG's app-user
    secret format). Also the password source for the import's externalCluster
    (same user owns the DB, so pg_dump over the wire just works).
  * ExternalSecret `postgres-wal-s3` — barman's S3 credentials, from the
    terraform-owned `/k8s/postgres/wal-s3-credentials` parameter.
  * ObjectStore — the barman-cloud plugin's S3 target. The Cluster's plugin
    reference carries a versioned `serverName` (`pg-<env>-v1`): a future
    re-bootstrap into the same bucket bumps it so old and new WAL timelines
    never interleave.
  * Cluster `pg` — pinned `standard`-flavor image (bundles pgvector),
    2Gi limit + bounded maintenance memory: the import rebuilds the
    frame_embeddings HNSW index, the exact operation that OOM-killed prod
    at 1Gi (2026-06-15).
  * ScheduledBackup — daily base backup; WAL segments stream continuously
    regardless.
"""

from __future__ import annotations

import cdk8s
from constructs import Construct

from adanalife_k8s.config import EnvConfig
from adanalife_k8s.naming import meta_labels

CLUSTER_NAME = "pg"  # services pg-rw / pg-ro; apps repoint DATABASE_HOST here
APP_CREDS_SECRET = "pg-app-creds"
WAL_S3_SECRET = "postgres-wal-s3"
OBJECT_STORE_NAME = "pg-store"

# The barman-cloud CNPG-I plugin's registered name (the operator side is the
# `plugin-barman-cloud` platform Helm component in cnpg-system).
_BARMAN_PLUGIN = "barman-cloud.cloudnative-pg.io"

# Pinned exact build of the CNPG `standard` image flavor — PG16 to match the
# live pgvector/pg16 server, `standard` because it bundles pgvector (verify
# bundled pgvector >= the live extversion before each env's cutover; live is
# 0.8.2 on PG 16.14).
_IMAGE = "ghcr.io/cloudnative-pg/postgresql:16.14-202607130907-standard-bookworm"

# The application database and its owning role. The password lives in SSM
# (rendered by ESO into pg-app-creds); the names are plain config — CNPG's
# initdb/import spec takes them as literals, so they can't ride in a Secret.
_DB_NAME = "tripbot"
_DB_OWNER = "tripbot"

# SSM parameter paths (terraform-owned; see terraform/*/postgres-wal.tf).
_CREDS_SM = "/k8s/postgres/credentials"
_WAL_SM = "/k8s/postgres/wal-s3-credentials"


def _meta(name: str, ns: str | None, labels: dict) -> dict:
    meta: dict = {"name": name, "labels": labels}
    if ns:
        meta["namespace"] = ns
    return meta


class CnpgCluster(Construct):
    def __init__(self, scope: Construct, *, env: EnvConfig):
        super().__init__(scope, CLUSTER_NAME)
        ns = env.data_ns or None
        labels = meta_labels(CLUSTER_NAME)

        # --- pg-app-creds: the SSM {user,password} as a basic-auth Secret ---
        # CNPG expects the app-user secret as kubernetes.io/basic-auth with
        # username/password keys. Same credentials as the legacy
        # postgres-secret — no password change rides this migration.
        self._external_secret(
            "app-creds",
            "pg-app-creds",
            ns,
            labels,
            target=APP_CREDS_SECRET,
            secret_type="kubernetes.io/basic-auth",
            data=[
                ("username", _CREDS_SM, "user"),
                ("password", _CREDS_SM, "password"),
            ],
            template={
                "username": "{{ .username }}",
                "password": "{{ .password }}",
            },
        )

        # --- postgres-wal-s3: barman's S3 credentials ---
        self._external_secret(
            "wal-s3-credentials",
            "postgres-wal-s3-credentials",
            ns,
            labels,
            target=WAL_S3_SECRET,
            data=[
                ("ACCESS_KEY_ID", _WAL_SM, "ACCESS_KEY_ID"),
                ("SECRET_ACCESS_KEY", _WAL_SM, "SECRET_ACCESS_KEY"),
                ("REGION", _WAL_SM, "REGION"),
            ],
            template={
                "ACCESS_KEY_ID": "{{ .ACCESS_KEY_ID }}",
                "SECRET_ACCESS_KEY": "{{ .SECRET_ACCESS_KEY }}",
                "REGION": "{{ .REGION }}",
            },
        )

        # --- ObjectStore: the barman-cloud S3 target ---
        store = cdk8s.ApiObject(
            self,
            "object-store",
            api_version="barmancloud.cnpg.io/v1",
            kind="ObjectStore",
            metadata=_meta(OBJECT_STORE_NAME, ns, labels),
        )
        store.add_json_patch(
            cdk8s.JsonPatch.add(
                "/spec",
                {
                    "configuration": {
                        # The bucket name is derivable public config (it
                        # follows the account naming scheme); access needs the
                        # SSM-held keys.
                        "destinationPath": f"s3://adanalife-{env.name}-postgres-wal/",
                        "s3Credentials": {
                            "accessKeyId": {
                                "name": WAL_S3_SECRET,
                                "key": "ACCESS_KEY_ID",
                            },
                            "secretAccessKey": {
                                "name": WAL_S3_SECRET,
                                "key": "SECRET_ACCESS_KEY",
                            },
                            "region": {"name": WAL_S3_SECRET, "key": "REGION"},
                        },
                        "wal": {"compression": "gzip"},
                        "data": {"compression": "gzip"},
                    },
                    # barman owns object expiry; the bucket's terraform
                    # lifecycle only cleans noncurrent versions + aborted
                    # multipart uploads.
                    "retentionPolicy": "30d",
                },
            )
        )

        # --- Cluster: single instance, import-bootstrapped from the legacy STS ---
        cluster = cdk8s.ApiObject(
            self,
            "cluster",
            api_version="postgresql.cnpg.io/v1",
            kind="Cluster",
            metadata=_meta(CLUSTER_NAME, ns, labels),
        )
        cluster.add_json_patch(
            cdk8s.JsonPatch.add(
                "/spec",
                {
                    "instances": 1,
                    "imageName": _IMAGE,
                    "storage": {
                        "size": env.postgres_size,
                        **(
                            {"storageClass": env.postgres_storage_class}
                            if env.postgres_storage_class
                            else {}
                        ),
                    },
                    "resources": {
                        "requests": {"cpu": "100m", "memory": "256Mi"},
                        # Same OOM story as the legacy container: the HNSW
                        # index build on frame_embeddings needs the headroom.
                        "limits": {"memory": "2Gi"},
                    },
                    "postgresql": {
                        "parameters": {
                            # WAL segments ship at least this often even when
                            # write volume is low — this bound IS the RPO.
                            "archive_timeout": "5min",
                            # Bounded on-disk HNSW build (the anti-OOM
                            # settings the 2026-06-15 incident taught): the
                            # import rebuilds the frame_embeddings index.
                            "maintenance_work_mem": "128MB",
                            "max_parallel_maintenance_workers": "0",
                        },
                    },
                    "plugins": [
                        {
                            "name": _BARMAN_PLUGIN,
                            "isWALArchiver": True,
                            "parameters": {
                                "barmanObjectName": OBJECT_STORE_NAME,
                                # Versioned so a re-bootstrap into the same
                                # bucket can bump to -v2 instead of
                                # interleaving WAL histories. (The CRD rejects
                                # serverName on the ObjectStore side.)
                                "serverName": f"pg-{env.name}-v1",
                            },
                        }
                    ],
                    "bootstrap": {
                        "initdb": {
                            "database": _DB_NAME,
                            "owner": _DB_OWNER,
                            "secret": {"name": APP_CREDS_SECRET},
                            # One-shot logical import from the legacy Service
                            # at first bootstrap; inert once the cluster
                            # exists. microservice type = just this database,
                            # dumped and restored with its owner's own creds.
                            "import": {
                                "type": "microservice",
                                "databases": [_DB_NAME],
                                "source": {"externalCluster": "legacy"},
                            },
                        }
                    },
                    "externalClusters": [
                        {
                            "name": "legacy",
                            # Same-namespace lookup, like the backup CronJob's
                            # --host=postgres.
                            "connectionParameters": {
                                "host": "postgres",
                                "user": _DB_OWNER,
                                "dbname": _DB_NAME,
                            },
                            "password": {
                                "name": APP_CREDS_SECRET,
                                "key": "password",
                            },
                        }
                    ],
                },
            )
        )

        # --- ScheduledBackup: daily base backup at 04:00 UTC ---
        backup = cdk8s.ApiObject(
            self,
            "scheduled-backup",
            api_version="postgresql.cnpg.io/v1",
            kind="ScheduledBackup",
            metadata=_meta("pg-daily", ns, labels),
        )
        backup.add_json_patch(
            cdk8s.JsonPatch.add(
                "/spec",
                {
                    # CNPG cron has a leading seconds field (not 5-field
                    # CronJob syntax): daily at 04:00:00 UTC.
                    "schedule": "0 0 4 * * *",
                    "cluster": {"name": CLUSTER_NAME},
                    "method": "plugin",
                    "pluginConfiguration": {"name": _BARMAN_PLUGIN},
                    # First base backup right after bootstrap instead of
                    # waiting for the 04:00 slot — WAL archiving alone can't
                    # restore without a base to replay onto.
                    "immediate": True,
                    "backupOwnerReference": "self",
                },
            )
        )

    # ---- helpers ----
    def _external_secret(
        self, id, name, ns, labels, *, target, data, template, secret_type="Opaque"
    ):
        # Same raw-ApiObject idiom as postgres.py's ExternalSecrets (the ESO
        # CRD isn't in imports/k8s); this variant can emit non-Opaque types
        # (CNPG wants its app-creds secret as kubernetes.io/basic-auth).
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
                        "template": {"type": secret_type, "data": template},
                    },
                    "data": [
                        {"secretKey": sk, "remoteRef": {"key": k, "property": p}}
                        for sk, k, p in data
                    ],
                },
            )
        )
