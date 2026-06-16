"""Postgres construct tests.

The load-bearing assertion is the prod-1 volumeClaimTemplate: this construct is
applied via SSA to ADOPT the live prod StatefulSet that owns 50Gi of
irreplaceable data, so the VCT (50Gi / local-path-retain), the StatefulSet
name, serviceName, and selector/matchLabels must match the live spec exactly —
a drift would risk a StatefulSet replacement and data loss.
"""

from cdk8s import Chart
from cdk8s import Testing as K8sTesting

from adanalife_k8s.config import load_env
from adanalife_k8s.constructs.postgres import Postgres


def _synth(env_name):
    app = K8sTesting.app()
    chart = Chart(app, "t")
    Postgres(chart, env=load_env(env_name))
    return K8sTesting.synth(chart)


def _by(objs, kind, name):
    return [o for o in objs if o["kind"] == kind and o["metadata"]["name"] == name]


def _sts(objs):
    return _by(objs, "StatefulSet", "postgres")[0]


# --- the SSA-adoption guard: prod VCT must be EXACTLY 50Gi / local-path-retain ---


def test_prod_volume_claim_template_is_50gi_retain():
    sts = _sts(_synth("prod-1"))
    vcts = sts["spec"]["volumeClaimTemplates"]
    assert len(vcts) == 1
    vct = vcts[0]
    assert vct["metadata"]["name"] == "postgres-data"
    assert vct["spec"]["accessModes"] == ["ReadWriteOnce"]
    # The two values whose drift would orphan/replace the live data volume.
    assert vct["spec"]["resources"]["requests"]["storage"] == "50Gi"
    assert vct["spec"]["storageClassName"] == "local-path-retain"


def test_statefulset_immutable_join_keys_match_render():
    # name / serviceName / selector / pod labels are the immutable adoption keys.
    sts = _sts(_synth("prod-1"))
    assert sts["metadata"]["name"] == "postgres"
    assert sts["spec"]["serviceName"] == "postgres"
    assert sts["spec"]["selector"]["matchLabels"] == {"app": "postgres"}
    assert sts["spec"]["template"]["metadata"]["labels"] == {"app": "postgres"}
    assert sts["spec"]["replicas"] == 1


def test_headless_service_matches_render():
    svc = _by(_synth("prod-1"), "Service", "postgres")[0]
    assert svc["spec"]["clusterIP"] == "None"
    assert svc["spec"]["selector"] == {"app": "postgres"}
    port = svc["spec"]["ports"][0]
    assert port["name"] == "postgres"
    assert port["port"] == 5432
    assert port["targetPort"] == "postgres"


# --- container fidelity (image, probes, envFrom, mount) ---


def test_container_spec_matches_render():
    c = _sts(_synth("prod-1"))["spec"]["template"]["spec"]["containers"][0]
    assert c["image"] == "ghcr.io/adanalife/mirror/pgvector:pg16"
    assert c["securityContext"]["allowPrivilegeEscalation"] is False
    assert c["ports"][0] == {"name": "postgres", "containerPort": 5432}
    assert c["envFrom"][0]["secretRef"]["name"] == "postgres-secret"
    assert c["livenessProbe"]["exec"]["command"] == [
        "pg_isready",
        "-U",
        "$(POSTGRES_USER)",
    ]
    assert c["readinessProbe"]["tcpSocket"]["port"] == "postgres"
    mount = c["volumeMounts"][0]
    assert mount["mountPath"] == "/var/lib/postgresql/data"
    assert mount["subPath"] == "pgdata"
    # pod-level seccomp hardening
    pod_sc = _sts(_synth("prod-1"))["spec"]["template"]["spec"]["securityContext"]
    assert pod_sc["seccompProfile"]["type"] == "RuntimeDefault"


# --- per-env volumeClaimTemplate sizing / storage class ---


def test_dev_vct_default_size_no_storage_class():
    sts = _sts(_synth("development"))
    vct = sts["spec"]["volumeClaimTemplates"][0]
    assert vct["spec"]["resources"]["requests"]["storage"] == "5Gi"
    # "" → omitted (cluster default), matching the dev render.
    assert "storageClassName" not in vct["spec"]


# --- backup CronJob: prod only ---


def test_backup_cronjob_prod_only():
    prod = _synth("prod-1")
    cj = _by(prod, "CronJob", "postgres-backup")[0]
    assert cj["spec"]["schedule"] == "0 * * * *"
    assert cj["spec"]["suspend"] is False
    assert cj["spec"]["timeZone"] == "Etc/UTC"
    assert cj["spec"]["concurrencyPolicy"] == "Forbid"
    tmpl = cj["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    assert tmpl["restartPolicy"] == "Never"
    backup = tmpl["containers"][0]
    assert backup["image"] == "postgres:16-alpine"
    assert "pg_dump" in backup["args"][0]
    # vectors are derived + reproducible; excluding them keeps tiered dumps small
    assert "--exclude-table-data=frame_embeddings" in backup["args"][0]
    env_secrets = {e["secretRef"]["name"] for e in backup["envFrom"]}
    assert env_secrets == {"postgres-secret", "postgres-backup-s3"}
    # absent everywhere else
    for e in ("stage-1", "development", "local"):
        assert not _by(_synth(e), "CronJob", "postgres-backup")


# --- StorageClass: prod only ---


def test_storage_class_prod_only():
    sc = _by(_synth("prod-1"), "StorageClass", "local-path-retain")[0]
    assert sc["provisioner"] == "rancher.io/local-path"
    assert sc["reclaimPolicy"] == "Retain"
    assert sc["volumeBindingMode"] == "WaitForFirstConsumer"
    assert sc["allowVolumeExpansion"] is False
    for e in ("stage-1", "development", "local"):
        assert not _by(_synth(e), "StorageClass", "local-path-retain")


# --- ExternalSecret on eso envs; local Secret on the laptop overlay ---


def test_external_secret_on_eso_envs():
    for e in ("prod-1", "stage-1", "development"):
        objs = _synth(e)
        es = _by(objs, "ExternalSecret", "postgres-credentials")[0]
        assert es["spec"]["target"]["name"] == "postgres-secret"
        assert (
            es["spec"]["target"]["template"]["data"]["POSTGRES_USER"] == "{{ .user }}"
        )
        assert es["spec"]["secretStoreRef"]["name"] == "aws-secretsmanager"
        props = {d["remoteRef"]["property"] for d in es["spec"]["data"]}
        assert props == {"user", "password", "db"}
        # the local Secret must NOT appear on eso envs
        assert not _by(objs, "Secret", "postgres-secret")


def test_backup_external_secret_prod_only():
    es = _by(_synth("prod-1"), "ExternalSecret", "postgres-backup-s3-credentials")[0]
    assert es["spec"]["target"]["name"] == "postgres-backup-s3"
    props = {d["remoteRef"]["property"] for d in es["spec"]["data"]}
    assert props == {
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_DEFAULT_REGION",
        "S3_BUCKET",
    }
    for e in ("stage-1", "development", "local"):
        assert not _by(_synth(e), "ExternalSecret", "postgres-backup-s3-credentials")


def test_local_uses_inline_secret_not_eso():
    objs = _synth("local")
    # local has NO ExternalSecret — postgres-secret comes from the inline Secret.
    assert not _by(objs, "ExternalSecret", "postgres-credentials")
    sec = _by(objs, "Secret", "postgres-secret")[0]
    sd = sec.get("stringData") or sec.get("data")
    assert "POSTGRES_USER" in sd
    # the StatefulSet still envFroms the stable postgres-secret name
    c = _sts(objs)["spec"]["template"]["spec"]["containers"][0]
    assert c["envFrom"][0]["secretRef"]["name"] == "postgres-secret"
