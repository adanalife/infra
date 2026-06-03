"""OnscreensServer construct tests: per-env NATS_URL presence, image tag,
labels/selector correctness, and Deployment+Service across envs."""

from cdk8s import Chart
from cdk8s import Testing as K8sTesting

from adanalife_k8s.config import load_env
from adanalife_k8s.constructs.onscreens import OnscreensServer


def _synth(env_name):
    app = K8sTesting.app()
    chart = Chart(app, "t")
    OnscreensServer(chart, "twitch", env=load_env(env_name))
    return K8sTesting.synth(chart)


def _by(objs, kind, name):
    return [o for o in objs if o["kind"] == kind and o["metadata"]["name"] == name]


def test_deployment_and_service_in_every_env():
    for env in ("local", "development", "stage-1", "prod-1"):
        objs = _synth(env)
        assert _by(objs, "Deployment", "onscreens-twitch"), f"{env} missing Deployment"
        assert _by(objs, "Service", "onscreens-twitch"), f"{env} missing Service"
        assert _by(objs, "ConfigMap", "onscreens-twitch-config"), (
            f"{env} missing ConfigMap"
        )
        # No Ingress anywhere — cluster-internal only.
        assert not [o for o in objs if o["kind"] == "Ingress"], (
            f"{env} should have no Ingress"
        )


def test_nats_url_present_on_platform_envs_absent_on_local():
    # dev/stage/prod have a platform NATS; local does not (subscriber no-ops).
    for env, expected in [
        ("development", "nats://nats.development-platform.svc.cluster.local:4222"),
        ("stage-1", "nats://nats.stage-1-platform.svc.cluster.local:4222"),
        ("prod-1", "nats://nats.prod-1-platform.svc.cluster.local:4222"),
    ]:
        cm = _by(_synth(env), "ConfigMap", "onscreens-twitch-config")[0]["data"]
        assert cm["NATS_URL"] == expected
    local_cm = _by(_synth("local"), "ConfigMap", "onscreens-twitch-config")[0]["data"]
    assert "NATS_URL" not in local_cm


def test_image_tag_per_env():
    # prod + local ride :latest; dev + stage pin :develop.
    def image(env):
        dep = _by(_synth(env), "Deployment", "onscreens-twitch")[0]
        return dep["spec"]["template"]["spec"]["containers"][0]["image"]

    assert image("prod-1") == "adanalife/onscreens-server:latest"
    assert image("local") == "adanalife/onscreens-server:latest"
    assert image("stage-1") == "adanalife/onscreens-server:develop"
    assert image("development") == "adanalife/onscreens-server:develop"


def test_labels_and_selector_match_convention():
    objs = _synth("stage-1")
    dep = _by(objs, "Deployment", "onscreens-twitch")[0]
    svc = _by(objs, "Service", "onscreens-twitch")[0]
    # metadata labels = app.kubernetes.io/* ONLY (includeSelectors:false).
    for obj in (dep, svc):
        labels = obj["metadata"]["labels"]
        assert labels == {
            "app.kubernetes.io/name": "onscreens-twitch",
            "app.kubernetes.io/part-of": "tripbot",
        }
    # selector + pod-template labels = app:onscreens-twitch ONLY.
    assert dep["spec"]["selector"]["matchLabels"] == {"app": "onscreens-twitch"}
    assert dep["spec"]["template"]["metadata"]["labels"] == {"app": "onscreens-twitch"}
    assert svc["spec"]["selector"] == {"app": "onscreens-twitch"}


def test_config_telemetry_block_and_hash_annotation():
    objs = _synth("prod-1")
    cm = _by(objs, "ConfigMap", "onscreens-twitch-config")[0]["data"]
    # prod telemetry tags + OTEL enabled.
    assert cm["ENV"] == "production"
    assert cm["SENTRY_ENVIRONMENT"] == "prod-1"
    assert cm["OTEL_SDK_DISABLED"] == "false"
    assert cm["OTEL_TRACES_SAMPLER"] == "parentbased_traceidratio"
    # No stub block (DB/Twitch) — onscreens config only needs ENV.
    assert "DATABASE_USER" not in cm
    # ConfigMap name is STABLE (not kustomize-hashed) and pod carries the hash.
    dep = _by(objs, "Deployment", "onscreens-twitch")[0]
    ann = dep["spec"]["template"]["metadata"]["annotations"]
    assert "adanalife.dev/config-hash" in ann


def test_service_and_probe_shape():
    objs = _synth("development")
    svc = _by(objs, "Service", "onscreens-twitch")[0]["spec"]
    assert svc["type"] == "ClusterIP"
    port = svc["ports"][0]
    assert (
        port["name"] == "http" and port["port"] == 8080 and port["targetPort"] == "http"
    )
    container = _by(objs, "Deployment", "onscreens-twitch")[0]["spec"]["template"][
        "spec"
    ]["containers"][0]
    assert container["livenessProbe"]["httpGet"]["path"] == "/health/live"
    assert container["readinessProbe"]["httpGet"]["path"] == "/health/ready"
    # envFrom: stable config + the two shared observability secrets.
    cm_refs = [e for e in container["envFrom"] if "configMapRef" in e]
    assert cm_refs[0]["configMapRef"]["name"] == "onscreens-twitch-config"
