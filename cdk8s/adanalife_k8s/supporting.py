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
from adanalife_k8s.constructs.arc import RUNNER_SA, RUNNERS_NS
from adanalife_k8s.eso import ESData, external_secret

# Sentry DSNs for tripbot / onscreens-server — dataFrom.extract from SSM
# Parameter Store into the env namespace, envFrom'd with optional: true.
_SHARED_SECRETS = [
    ("sentry-tripbot", "/k8s/sentry-tripbot"),
    ("sentry-onscreens-server", "/k8s/sentry-onscreens-server"),
]


def emit_supporting(scope: Construct, env: EnvConfig) -> None:
    """shared-secrets + the per-namespace cert-manager ACME Issuers (and their
    Route53 credential) for an eso env. The ESO
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
    if env.name == "stage-1":
        _ci_rollout_rbac(scope, env.namespace)


# Stage runs every workload off a floating `:main` image with
# imagePullPolicy: Always, so a merge reaches it only when a pod restarts. The
# shared image workflow's `roll-stage` job (.github/workflows/image.yml) runs
# on the ARC pool after each :main push and patches the pod template's
# restartedAt annotation, the same gesture as `kubectl rollout restart` and the
# console's restart button; this is the grant that lets the runner pods do it.
# Stage only: prod pins release tags and rolls by sync.
CI_ROLLOUT_ROLE = "ci-stage-rollout"


def _ci_rollout_rbac(scope: Construct, ns: str) -> None:
    k8s.KubeRole(
        scope,
        "ci-rollout-role",
        metadata=k8s.ObjectMeta(name=CI_ROLLOUT_ROLE, namespace=ns),
        rules=[
            # get to read the rollout back, patch for the restart annotation.
            k8s.PolicyRule(
                api_groups=["apps"], resources=["deployments"], verbs=["get", "patch"]
            ),
            # The new pods' image digests, so the job can prove stage runs the
            # image this run pushed rather than a :main the build raced.
            k8s.PolicyRule(api_groups=[""], resources=["pods"], verbs=["list"]),
        ],
    )
    k8s.KubeRoleBinding(
        scope,
        "ci-rollout-rolebinding",
        metadata=k8s.ObjectMeta(name=CI_ROLLOUT_ROLE, namespace=ns),
        role_ref=k8s.RoleRef(
            api_group="rbac.authorization.k8s.io", kind="Role", name=CI_ROLLOUT_ROLE
        ),
        subjects=[
            k8s.Subject(kind="ServiceAccount", name=RUNNER_SA, namespace=RUNNERS_NS)
        ],
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
            ESData("access-key-id", "/k8s/external-dns/aws-credentials", "access-key"),
            ESData(
                "secret-access-key", "/k8s/external-dns/aws-credentials", "secret-key"
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
