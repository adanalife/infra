"""Namespace-scoped supporting resources the env umbrella pulls in alongside the
apps: the per-ns ESO SecretStore, the cross-cutting observability ExternalSecrets
(shared-secrets), and the namespaced cert-manager Issuers (+ their Route53 creds).

These are emitted by `AppsChart` so a single `kubectl apply` of the env file
stands up the same set the Kustomize umbrella did. They are skipped for the
`local` env (no ESO / no cert-manager there).
"""
from __future__ import annotations

import cdk8s
from constructs import Construct

from adanalife_k8s.config import EnvConfig
from adanalife_k8s.eso import ESData, external_secret, secret_store

# Cross-cutting observability secrets (k8s/shared-secrets/base) — all
# dataFrom.extract from SM, materialized into the env namespace, envFrom'd by
# tripbot / vlc-server with optional: false.
_SHARED_SECRETS = [
    ("grafana-cloud-otlp", "k8s/grafana-cloud-otlp"),
    ("sentry-tripbot", "k8s/sentry-tripbot"),
    ("sentry-vlc-server", "k8s/sentry-vlc-server"),
]


def emit_supporting(scope: Construct, env: EnvConfig) -> None:
    """SecretStore + shared-secrets + cert-manager app-issuers for an eso env."""
    if env.secret_source != "eso":
        return  # local env: no ESO, no cert-manager

    ns = env.namespace or None
    secret_store(scope, "secret-store", namespace=ns)

    for name, sm_key in _SHARED_SECRETS:
        external_secret(scope, f"shared-{name}", name=name, namespace=ns,
                        extract=sm_key, creation_policy="Owner")

    _app_issuers(scope, env, ns)


def _app_issuers(scope: Construct, env: EnvConfig, ns: str | None) -> None:
    """Namespaced cert-manager Issuers (LE staging + prod) for app ingresses,
    plus the DNS-01 Route53 creds ExternalSecret they solve with."""
    # Route53 solver creds — discrete keys (cert-manager wants them split, not
    # external-dns's INI blob), so per-key remoteRef + property (ESO pattern 2).
    external_secret(
        scope, "cert-manager-aws-credentials",
        name="cert-manager-aws-credentials", namespace=ns,
        data=[
            ESData("access-key-id", "k8s/external-dns/aws-credentials", "access-key"),
            ESData("secret-access-key", "k8s/external-dns/aws-credentials", "secret-key"),
        ],
    )

    for issuer_name, acme_server, account_key in (
        ("letsencrypt-staging-route53",
         "https://acme-staging-v02.api.letsencrypt.org/directory",
         "letsencrypt-staging-route53-account"),
        ("letsencrypt-route53",
         "https://acme-v02.api.letsencrypt.org/directory",
         "letsencrypt-route53-account"),
    ):
        issuer = cdk8s.ApiObject(
            scope, issuer_name,
            api_version="cert-manager.io/v1", kind="Issuer",
            metadata={"name": issuer_name, **({"namespace": ns} if ns else {})},
        )
        issuer.add_json_patch(cdk8s.JsonPatch.add("/spec", {
            "acme": {
                "server": acme_server,
                "email": "danadotlol@gmail.com",
                "privateKeySecretRef": {"name": account_key},
                "solvers": [{"dns01": {"route53": {
                    "region": "us-east-1",
                    "accessKeyIDSecretRef": {"name": "cert-manager-aws-credentials", "key": "access-key-id"},
                    "secretAccessKeySecretRef": {"name": "cert-manager-aws-credentials", "key": "secret-access-key"},
                    "role": env.external_dns_role_arn,
                }}}],
            },
        }))
