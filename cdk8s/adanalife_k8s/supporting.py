"""Namespace-scoped supporting resources the env umbrella pulls in alongside the
apps: the cross-cutting observability ExternalSecrets (shared-secrets) and the
namespaced cert-manager Issuers (+ their Route53 creds).

These are emitted by `SupportingChart`. The ESO SecretStore they reference is emitted
by `DataChart` (the synced-first unit) so the data unit is self-sufficient — see
DataChart. Skipped for the `local` env (no ESO / no cert-manager there).
"""

from __future__ import annotations

from constructs import Construct

import imports.io.cert_manager as cm
import imports.k8s as k8s
from adanalife_k8s.config import EnvConfig
from adanalife_k8s.eso import ESData, external_secret

# Cross-cutting observability secrets (k8s/shared-secrets/base) — all
# dataFrom.extract from SM, materialized into the env namespace, envFrom'd by
# tripbot / vlc-server with optional: false.
_SHARED_SECRETS = [
    ("grafana-cloud-otlp", "k8s/grafana-cloud-otlp"),
    ("sentry-tripbot", "k8s/sentry-tripbot"),
    ("sentry-vlc-server", "k8s/sentry-vlc-server"),
    ("sentry-onscreens-server", "k8s/sentry-onscreens-server"),
]


def emit_supporting(scope: Construct, env: EnvConfig) -> None:
    """shared-secrets + cert-manager app-issuers for an eso env. The ESO
    SecretStore these reference is emitted by DataChart, not here."""
    if env.secret_source != "eso":
        return  # local env: no ESO, no cert-manager

    ns = env.namespace or None

    for name, sm_key in _SHARED_SECRETS:
        external_secret(
            scope,
            f"shared-{name}",
            name=name,
            namespace=ns,
            extract=sm_key,
            creation_policy="Owner",
        )

    _app_issuers(scope, env, ns)


def emit_stream_protection(scope: Construct, env: EnvConfig) -> None:
    """The prod-stream protection objects (2026-06-11 stage-starves-prod
    incident): the PriorityClass the env's app pods reference (when
    env.priority_class is set), and the app-namespace ResourceQuota capping
    what co-tenant envs can request in aggregate (when env.app_quota is set).
    """
    ns = env.namespace or None

    if env.priority_class:
        # Cluster-scoped; cdk8s stamps the chart namespace, which the apiserver
        # ignores on cluster-scoped kinds (same as dashcam-cv-low). value 1000
        # outranks every default-priority (0) pod, so under node pressure the
        # scheduler preempts co-tenants, never the live stream. dashcam-cv-low
        # (-10) stays the most-preemptible tier.
        k8s.KubePriorityClass(
            scope,
            "priority-class",
            metadata=k8s.ObjectMeta(name=env.priority_class),
            value=1000,
            global_default=False,
            description="Live-stream workloads — outrank default-priority co-tenants; preempt them under node pressure.",
        )

    if env.app_quota:
        k8s.KubeResourceQuota(
            scope,
            "app-quota",
            metadata=k8s.ObjectMeta(name="app-quota", namespace=ns),
            spec=k8s.ResourceQuotaSpec(
                hard={
                    key: k8s.Quantity.from_string(val)
                    for key, val in env.app_quota.items()
                }
            ),
        )


def _app_issuers(scope: Construct, env: EnvConfig, ns: str | None) -> None:
    """Namespaced cert-manager Issuers (LE staging + prod) for app ingresses,
    plus the DNS-01 Route53 creds ExternalSecret they solve with."""
    # Route53 solver creds — discrete keys (cert-manager wants them split, not
    # external-dns's INI blob), so per-key remoteRef + property (ESO pattern 2).
    external_secret(
        scope,
        "cert-manager-aws-credentials",
        name="cert-manager-aws-credentials",
        namespace=ns,
        data=[
            ESData("access-key-id", "k8s/external-dns/aws-credentials", "access-key"),
            ESData(
                "secret-access-key", "k8s/external-dns/aws-credentials", "secret-key"
            ),
        ],
    )

    for issuer_name, acme_server, account_key in (
        (
            "letsencrypt-staging-route53",
            "https://acme-staging-v02.api.letsencrypt.org/directory",
            "letsencrypt-staging-route53-account",
        ),
        (
            "letsencrypt-route53",
            "https://acme-v02.api.letsencrypt.org/directory",
            "letsencrypt-route53-account",
        ),
    ):
        route53 = cm.IssuerSpecAcmeSolversDns01Route53(
            region="us-east-1",
            access_key_id_secret_ref=cm.IssuerSpecAcmeSolversDns01Route53AccessKeyIdSecretRef(
                name="cert-manager-aws-credentials", key="access-key-id"
            ),
            secret_access_key_secret_ref=cm.IssuerSpecAcmeSolversDns01Route53SecretAccessKeySecretRef(
                name="cert-manager-aws-credentials", key="secret-access-key"
            ),
            role=env.external_dns_role_arn,
        )
        cm.Issuer(
            scope,
            issuer_name,
            metadata={"name": issuer_name, **({"namespace": ns} if ns else {})},
            spec=cm.IssuerSpec(
                acme=cm.IssuerSpecAcme(
                    server=acme_server,
                    email="danadotlol@gmail.com",
                    private_key_secret_ref=cm.IssuerSpecAcmePrivateKeySecretRef(
                        name=account_key
                    ),
                    solvers=[
                        cm.IssuerSpecAcmeSolvers(
                            dns01=cm.IssuerSpecAcmeSolversDns01(route53=route53)
                        )
                    ],
                )
            ),
        )
