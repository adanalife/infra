"""SupportingChart tests: the shared observability ExternalSecrets and
cert-manager Issuers — the per-env namespace supporting layer infra still emits
(once per env, not per platform/component).

tripbot's identity Secrets (DB creds + twitch/maps/discord) and the prod-stream
protection objects moved to the tripbot repo's cdk8s (delivered by the
tripbot-identity ApplicationSet); they're covered by tripbot's own test suite."""

from cdk8s import Testing as K8sTesting

from adanalife_k8s.charts import SupportingChart
from adanalife_k8s.config import load_env


def _synth(env_name):
    app = K8sTesting.app()
    chart = SupportingChart(app, "t", env=load_env(env_name))
    return K8sTesting.synth(chart)


def _by(objs, kind, name):
    return [o for o in objs if o["kind"] == kind and o["metadata"]["name"] == name]


def test_shared_observability_secrets_and_issuers_on_eso_env():
    objs = _synth("prod-1")
    es = {o["metadata"]["name"] for o in objs if o["kind"] == "ExternalSecret"}
    # cross-cutting observability secrets vlc/onscreens/tripbot envFrom
    assert {"grafana-cloud-otlp", "sentry-tripbot", "sentry-vlc-server"} <= es
    # cert-manager app issuers (LE staging + prod) + their Route53 creds
    issuers = {o["metadata"]["name"] for o in objs if o["kind"] == "Issuer"}
    assert {"letsencrypt-staging-route53", "letsencrypt-route53"} <= issuers
    assert _by(objs, "ExternalSecret", "cert-manager-aws-credentials")
    # identity Secrets are NOT emitted here anymore (they moved to the tripbot repo)
    assert not _by(objs, "ExternalSecret", "tripbot-database-creds")
    assert not _by(objs, "ExternalSecret", "tripbot-twitch-creds")


def test_local_supporting_has_no_eso_or_issuers():
    # local skips ESO + cert-manager entirely (emit_supporting returns early), and
    # the laptop DB Secret + identity now come from the tripbot repo's local dist.
    objs = _synth("local")
    assert not [o for o in objs if o["kind"] == "ExternalSecret"]
    assert not [o for o in objs if o["kind"] == "Issuer"]
    assert not _by(objs, "Secret", "tripbot-secret")
