"""Data-namespace isolation: the opt-in `data_namespace` knob moves postgres (+
its ESO SecretStore) into its own namespace so deleting the app namespace can't
drop the database, while keeping the dashcam PVC in the app namespace (vlc mounts
it — PVCs are namespace-local).

Stage rehearses isolation (data_namespace=stage-1-data); prod/dev/local stay
co-located (data_namespace=""), where the render must be byte-identical to before
the knob existed — so these tests pin both the isolated and the co-located shapes.
"""

from cdk8s import Testing as K8sTesting

from adanalife_k8s.charts import DataChart, SupportingChart
from adanalife_k8s.config import load_env
from adanalife_k8s.constructs.tripbot import config_data


def _synth(chart_cls, env_name):
    app = K8sTesting.app()
    chart = chart_cls(app, "t", env=load_env(env_name))
    return K8sTesting.synth(chart)


def _by(objs, kind, name):
    return [o for o in objs if o["kind"] == kind and o["metadata"]["name"] == name]


def _ns(obj):
    return obj["metadata"].get("namespace")


# --- EnvConfig derived properties ---


def test_isolated_env_properties():
    stage = load_env("stage-1")
    assert stage.data_namespace == "stage-1-data"
    assert stage.data_isolated is True
    assert stage.data_ns == "stage-1-data"
    assert stage.postgres_host == "postgres.stage-1-data.svc.cluster.local"


def test_colocated_env_properties_unchanged():
    # prod (and dev/local) keep the DB in the app namespace with a bare host —
    # the pre-knob behavior, so the render stays byte-identical.
    for name in ("prod-1", "development", "local"):
        env = load_env(name)
        assert env.data_namespace == ""
        assert env.data_isolated is False
        assert env.data_ns == env.namespace
        assert env.postgres_host == "postgres"


# --- isolated (stage): postgres + store -> data ns; PVC -> app ns ---


def test_isolated_postgres_and_store_land_in_data_namespace():
    objs = _synth(DataChart, "stage-1")
    for kind, name in (
        ("StatefulSet", "postgres"),
        ("Service", "postgres"),
        ("ExternalSecret", "postgres-credentials"),
        ("SecretStore", "aws-secretsmanager"),
    ):
        assert _ns(_by(objs, kind, name)[0]) == "stage-1-data"
    # the dashcam PVC must NOT ride along into the data namespace (vlc mounts it)
    assert not _by(objs, "PersistentVolumeClaim", "vlc-dashcam")


def test_isolated_supporting_gains_app_ns_store_and_dashcam_pvc():
    objs = _synth(SupportingChart, "stage-1")
    # the app namespace needs its OWN store (postgres' moved to the data ns)
    store = _by(objs, "SecretStore", "aws-secretsmanager")[0]
    assert _ns(store) == "stage-1"
    # ...and the dashcam PVC lands here, in the app namespace, bound to its PV
    pvc = _by(objs, "PersistentVolumeClaim", "vlc-dashcam")[0]
    assert _ns(pvc) == "stage-1"
    assert pvc["spec"]["volumeName"] == "vlc-dashcam-nfs-stage"


# --- co-located (prod): everything stays put, no duplicate store ---


def test_colocated_keeps_postgres_and_pvc_in_app_namespace():
    objs = _synth(DataChart, "prod-1")
    assert _ns(_by(objs, "StatefulSet", "postgres")[0]) == "prod-1"
    assert _ns(_by(objs, "SecretStore", "aws-secretsmanager")[0]) == "prod-1"
    # the dashcam PVC stays in the data unit when co-located
    assert _ns(_by(objs, "PersistentVolumeClaim", "vlc-dashcam")[0]) == "prod-1"


def test_colocated_supporting_has_no_duplicate_store_or_pvc():
    # the single same-namespace store in DataChart serves the app ES too, so
    # SupportingChart must NOT emit a second one (which would collide), nor the PVC.
    objs = _synth(SupportingChart, "prod-1")
    assert not _by(objs, "SecretStore", "aws-secretsmanager")
    assert not _by(objs, "PersistentVolumeClaim", "vlc-dashcam")


# --- DATABASE_HOST in the tripbot ConfigMap follows the env ---


def test_database_host_is_fqdn_when_isolated_bare_when_not():
    assert (
        config_data(load_env("stage-1"), "twitch")["DATABASE_HOST"]
        == "postgres.stage-1-data.svc.cluster.local"
    )
    assert config_data(load_env("prod-1"), "twitch")["DATABASE_HOST"] == "postgres"
