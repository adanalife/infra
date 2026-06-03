"""Tripbot construct + Jobs tests: stable tripbot-config, the 5 ExternalSecrets,
per-env identity config, outbound-only ingress shape, image tag, local DB Secret,
and the one-shot Jobs (which envFrom the stable config and are NOT auto-emitted)."""

from cdk8s import Chart
from cdk8s import Testing as K8sTesting

from adanalife_k8s.config import load_env
from adanalife_k8s.constructs import tripbot as tb
from adanalife_k8s.constructs.tripbot import Tripbot


def _synth(env_name):
    app = K8sTesting.app()
    chart = Chart(app, "t")
    Tripbot(chart, env=load_env(env_name))
    return K8sTesting.synth(chart)


def _synth_jobs(env_name):
    app = K8sTesting.app()
    chart = Chart(app, "t")
    tb.emit_jobs(chart, env=load_env(env_name))
    return K8sTesting.synth(chart)


def _by(objs, kind, name):
    return [o for o in objs if o["kind"] == kind and o["metadata"]["name"] == name]


# ---- ConfigMap: stable name + content hash ----


def test_config_map_is_stable_named_with_hash_annotation():
    objs = _synth("stage-1")
    cm = _by(objs, "ConfigMap", "tripbot-config")
    assert cm, "tripbot-config must keep its stable (non-hashed) name"
    # the only ConfigMap; no hash-suffixed variant
    assert [o for o in objs if o["kind"] == "ConfigMap"] == cm
    dep = _by(objs, "Deployment", "tripbot")[0]
    ann = dep["spec"]["template"]["metadata"]["annotations"]
    assert "adanalife.dev/config-hash" in ann


def test_deployment_and_jobs_reference_stable_config():
    dep = _by(_synth("prod-1"), "Deployment", "tripbot")[0]
    spec = dep["spec"]["template"]["spec"]
    # both the migrate initContainer and the main container envFrom tripbot-config
    for c in (spec["initContainers"][0], spec["containers"][0]):
        names = [e.get("configMapRef", {}).get("name") for e in c["envFrom"]]
        assert "tripbot-config" in names
    # every Job envFroms the stable name too
    for env in ("prod-1", "local"):
        for job in [o for o in _synth_jobs(env) if o["kind"] == "Job"]:
            pod = job["spec"]["template"]["spec"]
            cs = pod.get("containers", []) + pod.get("initContainers", [])
            assert any(
                e.get("configMapRef", {}).get("name") == "tripbot-config"
                for c in cs
                for e in c.get("envFrom", [])
            )


# ---- ExternalSecrets ----


def test_five_external_secrets_on_eso_envs_with_remote_keys():
    objs = _synth("stage-1")
    names = {o["metadata"]["name"] for o in objs if o["kind"] == "ExternalSecret"}
    assert names == {
        "tripbot-database-creds",
        "tripbot-twitch-creds",
        "tripbot-google-maps-api-key",
        "tripbot-discord-alerts-webhook",
        "tripbot-discord-bot-token",
    }
    # database: target.template remaps the shared postgres SM JSON onto DATABASE_*
    db = _by(objs, "ExternalSecret", "tripbot-database-creds")[0]["spec"]
    assert db["target"]["template"]["data"]["DATABASE_USER"] == "{{ .user }}"
    assert {d["remoteRef"]["key"] for d in db["data"]} == {"k8s/postgres/credentials"}
    assert {d["remoteRef"]["property"] for d in db["data"]} == {
        "user",
        "password",
        "db",
    }
    # twitch + maps use dataFrom.extract
    tw = _by(objs, "ExternalSecret", "tripbot-twitch-creds")[0]["spec"]
    assert tw["dataFrom"][0]["extract"]["key"] == "k8s/tripbot/twitch-creds"
    gm = _by(objs, "ExternalSecret", "tripbot-google-maps-api-key")[0]["spec"]
    assert gm["dataFrom"][0]["extract"]["key"] == "k8s/tripbot/google-maps-api-key"
    # discord: bare remoteRef → named key
    da = _by(objs, "ExternalSecret", "tripbot-discord-alerts-webhook")[0]["spec"]
    assert da["data"][0]["secretKey"] == "DISCORD_ALERTS_WEBHOOK"
    assert da["data"][0]["remoteRef"]["key"] == "k8s/tripbot/discord-alerts-webhook"
    bt = _by(objs, "ExternalSecret", "tripbot-discord-bot-token")[0]["spec"]
    assert bt["data"][0]["remoteRef"]["key"] == "k8s/tripbot/discord-bot-token"


def test_local_drops_db_external_secret_and_builds_secret():
    objs = _synth("local")
    # No cloud DB ExternalSecret on the laptop...
    assert not _by(objs, "ExternalSecret", "tripbot-database-creds")
    # ...but the other four ExternalSecrets still come from ESO.
    es = {o["metadata"]["name"] for o in objs if o["kind"] == "ExternalSecret"}
    assert es == {
        "tripbot-twitch-creds",
        "tripbot-google-maps-api-key",
        "tripbot-discord-alerts-webhook",
        "tripbot-discord-bot-token",
    }
    # A stable-named on-disk Secret carries the DB creds, and the Deployment
    # envFroms it (not tripbot-database-creds).
    sec = _by(objs, "Secret", "tripbot-secret")[0]
    assert sec["stringData"]["DATABASE_USER"] == "tripbot_docker"
    dep = _by(objs, "Deployment", "tripbot")[0]
    names = [
        e.get("secretRef", {}).get("name")
        for e in dep["spec"]["template"]["spec"]["containers"][0]["envFrom"]
    ]
    assert "tripbot-secret" in names
    assert "tripbot-database-creds" not in names


# ---- per-env identity config ----


def test_channel_and_bot_identity_per_env():
    prod = _by(_synth("prod-1"), "ConfigMap", "tripbot-config")[0]["data"]
    assert prod["CHANNEL_NAME"] == "adanalife_"
    assert prod["BOT_USERNAME"] == "tripbot4000"
    # prod uses the standalone onscreens-server (the in-pod :8081 hack is gone)
    assert prod["ONSCREENS_SERVER_HOST"] == "onscreens-server:8080"
    for env in ("stage-1", "development", "local"):
        cm = _by(_synth(env), "ConfigMap", "tripbot-config")[0]["data"]
        assert cm["CHANNEL_NAME"] == "adanalife_staging"
        assert cm["BOT_USERNAME"] == "tripbot4001"
        assert cm["ONSCREENS_SERVER_HOST"] == "onscreens-server:8080"
    # DISCORD_GUILD_ID is stage-only
    assert (
        "DISCORD_GUILD_ID"
        in _by(_synth("stage-1"), "ConfigMap", "tripbot-config")[0]["data"]
    )
    assert "DISCORD_GUILD_ID" not in prod


def test_telemetry_block_and_no_stub_block():
    prod = _by(_synth("prod-1"), "ConfigMap", "tripbot-config")[0]["data"]
    assert prod["ENV"] == "production"
    assert prod["OTEL_SDK_DISABLED"] == "false"
    assert prod["SENTRY_ENVIRONMENT"] == "prod-1"
    # tripbot's ConfigMap (unlike vlc's) carries NO DB/Twitch stub block —
    # those come from the Secret. Verify even on local/dev.
    for env in ("local", "development"):
        cm = _by(_synth(env), "ConfigMap", "tripbot-config")[0]["data"]
        assert "DATABASE_USER" not in cm
        assert "TWITCH_CLIENT_ID" not in cm


def test_nats_url_present_except_local():
    for env in ("prod-1", "stage-1", "development"):
        cm = _by(_synth(env), "ConfigMap", "tripbot-config")[0]["data"]
        assert cm["NATS_URL"].startswith("nats://")
    assert (
        "NATS_URL" not in _by(_synth("local"), "ConfigMap", "tripbot-config")[0]["data"]
    )


# ---- ingress shape per env ----


def test_ingress_minipc_has_tls_and_tailscale():
    objs = _synth("prod-1")
    ing = _by(objs, "Ingress", "tripbot")[0]
    assert ing["spec"]["rules"][0]["host"] == "tripbot.prod.whereisdana.today"
    assert ing["spec"]["tls"][0]["secretName"] == "tripbot-tls"
    assert (
        ing["metadata"]["annotations"]["cert-manager.io/issuer"]
        == "letsencrypt-route53"
    )
    # Tailscale Ingress (off-LAN dashboard) on minipc envs
    ts = _by(objs, "Ingress", "tripbot-ts")[0]
    assert ts["spec"]["ingressClassName"] == "tailscale"
    assert ts["spec"]["tls"][0]["hosts"] == ["tripbot-prod"]
    assert ts["spec"]["defaultBackend"]["service"]["port"]["number"] == 8080


def test_dev_ingress_has_tls_no_tailscale():
    objs = _synth("development")
    ing = _by(objs, "Ingress", "tripbot")[0]
    assert ing["spec"]["rules"][0]["host"] == "tripbot.dev.whereisdana.today"
    assert ing["spec"]["tls"][0]["secretName"] == "tripbot-tls"
    assert not _by(objs, "Ingress", "tripbot-ts")


def test_local_ingress_is_plain_http_localhost():
    objs = _synth("local")
    ing = _by(objs, "Ingress", "tripbot")[0]
    assert ing["spec"]["rules"][0]["host"] == "tripbot.localhost"
    assert "tls" not in ing["spec"] or not ing["spec"]["tls"]
    assert "annotations" not in ing["metadata"] or not ing["metadata"]["annotations"]
    assert not _by(objs, "Ingress", "tripbot-ts")


# ---- image tag per env ----


def test_image_tag_per_env():
    for env, tag in [
        ("prod-1", "latest"),
        ("local", "latest"),
        ("stage-1", "develop"),
        ("development", "develop"),
    ]:
        dep = _by(_synth(env), "Deployment", "tripbot")[0]
        spec = dep["spec"]["template"]["spec"]
        assert spec["containers"][0]["image"] == f"adanalife/tripbot:{tag}"
        assert spec["initContainers"][0]["image"] == f"adanalife/tripbot:{tag}"


# ---- one-shot Jobs ----


def test_eso_env_emits_three_jobs_with_account_legs():
    objs = _synth_jobs("stage-1")
    jobs = {o["metadata"]["name"] for o in objs if o["kind"] == "Job"}
    assert jobs == {
        "tripbot-auth-bootstrap-bot",
        "tripbot-auth-bootstrap-broadcaster",
        "tripbot-seed",
    }
    bot = _by(objs, "Job", "tripbot-auth-bootstrap-bot")[0]
    c = bot["spec"]["template"]["spec"]["containers"][0]
    assert c["args"] == ["--account=bot"]
    # eso bootstrap envFroms the ESO DB Secret + maps creds
    refs = [e.get("secretRef", {}).get("name") for e in c["envFrom"]]
    assert "tripbot-database-creds" in refs
    assert "tripbot-google-maps-api-key" in refs


def test_local_env_emits_combined_bootstrap_and_seed():
    objs = _synth_jobs("local")
    jobs = {o["metadata"]["name"] for o in objs if o["kind"] == "Job"}
    # local: one combined auth-bootstrap (no bot/broadcaster split) + seed
    assert jobs == {"tripbot-auth-bootstrap", "tripbot-seed"}
    auth = _by(objs, "Job", "tripbot-auth-bootstrap")[0]
    c = auth["spec"]["template"]["spec"]["containers"][0]
    assert "args" not in c or not c["args"]  # no --account
    refs = [e.get("secretRef", {}).get("name") for e in c["envFrom"]]
    assert "tripbot-secret" in refs  # secret.env DB creds, not ESO


def test_seed_job_shape():
    seed = _by(_synth_jobs("stage-1"), "Job", "tripbot-seed")[0]["spec"]
    assert seed["backoffLimit"] == 3
    pod = seed["template"]["spec"]
    init_names = [c["name"] for c in pod["initContainers"]]
    assert init_names == ["wait-for-postgres", "migrate"]
    assert pod["containers"][0]["command"] == ["/usr/local/bin/seed-db"]
