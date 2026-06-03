"""SupportingChart tests: tripbot's identity Secrets (DB creds + the twitch/maps/
discord ExternalSecrets) plus the shared observability ExternalSecrets and
cert-manager Issuers — the per-env namespace supporting layer, emitted once per
env (not per platform/component)."""

from cdk8s import Testing as K8sTesting

from adanalife_k8s.charts import SupportingChart
from adanalife_k8s.config import load_env

_TRIPBOT_IDENTITY_ES = {
    "tripbot-database-creds",
    "tripbot-twitch-creds",
    "tripbot-google-maps-api-key",
    "tripbot-discord-alerts-webhook",
    "tripbot-discord-bot-token",
}


def _synth(env_name):
    app = K8sTesting.app()
    chart = SupportingChart(app, "t", env=load_env(env_name))
    return K8sTesting.synth(chart)


def _by(objs, kind, name):
    return [o for o in objs if o["kind"] == kind and o["metadata"]["name"] == name]


def test_identity_external_secrets_on_eso_env_with_remote_keys():
    objs = _synth("stage-1")
    names = {o["metadata"]["name"] for o in objs if o["kind"] == "ExternalSecret"}
    assert _TRIPBOT_IDENTITY_ES <= names
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
    # discord: bare remoteRef → named key
    da = _by(objs, "ExternalSecret", "tripbot-discord-alerts-webhook")[0]["spec"]
    assert da["data"][0]["secretKey"] == "DISCORD_ALERTS_WEBHOOK"
    assert da["data"][0]["remoteRef"]["key"] == "k8s/tripbot/discord-alerts-webhook"


def test_shared_observability_secrets_and_issuers_on_eso_env():
    objs = _synth("prod-1")
    es = {o["metadata"]["name"] for o in objs if o["kind"] == "ExternalSecret"}
    # cross-cutting observability secrets vlc/onscreens/tripbot envFrom
    assert {"grafana-cloud-otlp", "sentry-tripbot", "sentry-vlc-server"} <= es
    # cert-manager app issuers (LE staging + prod) + their Route53 creds
    issuers = {o["metadata"]["name"] for o in objs if o["kind"] == "Issuer"}
    assert {"letsencrypt-staging-route53", "letsencrypt-route53"} <= issuers
    assert _by(objs, "ExternalSecret", "cert-manager-aws-credentials")


def test_local_builds_db_secret_and_drops_db_external_secret():
    objs = _synth("local")
    # No cloud DB ExternalSecret on the laptop...
    assert not _by(objs, "ExternalSecret", "tripbot-database-creds")
    # ...but the other four ExternalSecrets still come from ESO.
    es = {o["metadata"]["name"] for o in objs if o["kind"] == "ExternalSecret"}
    assert es == _TRIPBOT_IDENTITY_ES - {"tripbot-database-creds"}
    # A stable-named on-disk Secret carries the DB creds.
    sec = _by(objs, "Secret", "tripbot-secret")[0]
    assert sec["stringData"]["DATABASE_USER"] == "tripbot_docker"
    # local has no ESO shared-secrets / cert-manager (emit_supporting skips it)
    assert not _by(objs, "ExternalSecret", "sentry-tripbot")
    assert not [o for o in objs if o["kind"] == "Issuer"]
