"""CNPG cluster construct tests.

The load-bearing assertions are the ones a drift would turn into an incident:
the anti-OOM import settings (the frame_embeddings HNSW rebuild OOM-killed
prod at 1Gi on 2026-06-15), the archive_timeout that bounds the RPO, the
side-by-side naming (cluster `pg` must not collide with the legacy `postgres`
StatefulSet), and the env gate (prod-1 stays legacy-only until the stage PITR
drill passes).
"""

from cdk8s import Chart
from cdk8s import Testing as K8sTesting

from adanalife_k8s.charts import DataChart
from adanalife_k8s.config import load_env
from adanalife_k8s.constructs.cnpg import CnpgCluster


def _synth(env_name):
    app = K8sTesting.app()
    chart = Chart(app, "t")
    CnpgCluster(chart, env=load_env(env_name))
    return K8sTesting.synth(chart)


def _by(objs, kind, name=None):
    return [
        o
        for o in objs
        if o["kind"] == kind and (name is None or o["metadata"]["name"] == name)
    ]


def _cluster(objs):
    return _by(objs, "Cluster", "pg")[0]


# --- env gate: stage-1 only until the PITR drill passes ---


def test_stage_data_chart_emits_cnpg_prod_does_not():
    for env_name, expected in (("stage-1", True), ("prod-1", False)):
        app = K8sTesting.app()
        objs = K8sTesting.synth(DataChart(app, "t", env=load_env(env_name)))
        assert bool(_by(objs, "Cluster")) is expected
        assert bool(_by(objs, "ObjectStore")) is expected
        assert bool(_by(objs, "ScheduledBackup")) is expected
        # the legacy StatefulSet stays in both — side-by-side migration
        assert _by(objs, "StatefulSet", "postgres")


# --- the Cluster spec ---


def test_cluster_is_single_instance_pinned_standard_image():
    spec = _cluster(_synth("stage-1"))["spec"]
    assert spec["instances"] == 1
    image = spec["imageName"]
    # standard flavor (bundles pgvector), PG16, exact-pinned build
    assert image.startswith("ghcr.io/cloudnative-pg/postgresql:16.")
    assert "-standard-" in image


def test_cluster_carries_the_anti_oom_import_settings():
    spec = _cluster(_synth("stage-1"))["spec"]
    params = spec["postgresql"]["parameters"]
    assert params["maintenance_work_mem"] == "128MB"
    assert params["max_parallel_maintenance_workers"] == "0"
    assert spec["resources"]["limits"]["memory"] == "2Gi"


def test_cluster_archive_timeout_bounds_the_rpo():
    params = _cluster(_synth("stage-1"))["spec"]["postgresql"]["parameters"]
    assert params["archive_timeout"] == "5min"


def test_cluster_storage_matches_env():
    storage = _cluster(_synth("stage-1"))["spec"]["storage"]
    assert storage["size"] == "10Gi"
    assert storage["storageClass"] == "local-path"


def test_cluster_imports_from_the_legacy_service():
    spec = _cluster(_synth("stage-1"))["spec"]
    initdb = spec["bootstrap"]["initdb"]
    assert initdb["database"] == "tripbot"
    assert initdb["owner"] == "tripbot"
    assert initdb["secret"] == {"name": "pg-app-creds"}
    assert initdb["import"]["type"] == "microservice"
    assert initdb["import"]["databases"] == ["tripbot"]
    assert initdb["import"]["source"] == {"externalCluster": "legacy"}
    legacy = spec["externalClusters"][0]
    assert legacy["name"] == "legacy"
    # the legacy headless Service, same namespace — same lookup the backup
    # CronJob uses
    assert legacy["connectionParameters"]["host"] == "postgres"
    assert legacy["password"] == {"name": "pg-app-creds", "key": "password"}


def test_cluster_wires_the_barman_plugin_as_wal_archiver():
    plugins = _cluster(_synth("stage-1"))["spec"]["plugins"]
    assert plugins == [
        {
            "name": "barman-cloud.cloudnative-pg.io",
            "isWALArchiver": True,
            "parameters": {
                "barmanObjectName": "pg-store",
                # versioned serverName: a re-bootstrap bumps to -v2 rather
                # than interleaving WAL histories in the same prefix (the CRD
                # rejects serverName on the ObjectStore side)
                "serverName": "pg-stage-1-v1",
            },
        }
    ]


# --- the ObjectStore ---


def test_object_store_targets_the_env_wal_bucket():
    store = _by(_synth("stage-1"), "ObjectStore", "pg-store")[0]
    config = store["spec"]["configuration"]
    assert config["destinationPath"] == "s3://adanalife-stage-1-postgres-wal/"
    assert store["spec"]["retentionPolicy"] == "30d"
    for selector in ("accessKeyId", "secretAccessKey", "region"):
        assert config["s3Credentials"][selector]["name"] == "postgres-wal-s3"


# --- the ScheduledBackup ---


def test_scheduled_backup_daily_via_plugin_with_immediate_first():
    backup = _by(_synth("stage-1"), "ScheduledBackup", "pg-daily")[0]
    spec = backup["spec"]
    # CNPG cron carries a leading seconds field: 04:00:00 UTC daily
    assert spec["schedule"] == "0 0 4 * * *"
    assert spec["method"] == "plugin"
    assert spec["pluginConfiguration"] == {"name": "barman-cloud.cloudnative-pg.io"}
    assert spec["cluster"] == {"name": "pg"}
    assert spec["immediate"] is True


# --- the ExternalSecrets ---


def test_app_creds_secret_is_basic_auth_from_the_shared_ssm_param():
    es = _by(_synth("stage-1"), "ExternalSecret", "pg-app-creds")[0]
    target = es["spec"]["target"]
    assert target["name"] == "pg-app-creds"
    assert target["template"]["type"] == "kubernetes.io/basic-auth"
    refs = {d["secretKey"]: d["remoteRef"] for d in es["spec"]["data"]}
    # same SSM param as the legacy postgres-secret — one set of credentials
    assert refs["username"] == {"key": "/k8s/postgres/credentials", "property": "user"}
    assert refs["password"]["property"] == "password"


def test_wal_s3_secret_renders_the_barman_credential_keys():
    es = _by(_synth("stage-1"), "ExternalSecret", "postgres-wal-s3-credentials")[0]
    assert es["spec"]["target"]["name"] == "postgres-wal-s3"
    refs = {d["secretKey"]: d["remoteRef"] for d in es["spec"]["data"]}
    assert set(refs) == {"ACCESS_KEY_ID", "SECRET_ACCESS_KEY", "REGION"}
    for ref in refs.values():
        assert ref["key"] == "/k8s/postgres/wal-s3-credentials"


# --- namespacing ---


def test_everything_lands_in_the_data_namespace():
    for obj in _synth("stage-1"):
        assert obj["metadata"]["namespace"] == "stage-1-data"
