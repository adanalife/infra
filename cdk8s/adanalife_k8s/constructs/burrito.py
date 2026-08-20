"""Burrito trial config, authored in cdk8s. Synthesizes to dist/burrito.k8s.yaml
— a committed, golden-gated deploy unit applied (task k8s:prod:burrito:apply)
after the Burrito install (the `burrito` HelmComponent in helm_platform.py,
Argo-delivered via platform-argo). Burrito is the controller; these are the
objects that tell it what to plan:

  * TerraformRepository `infra` — the infra repo over anonymous HTTPS (public,
    so no deploy key — same as the obs/playout Argo sources).
  * TerraformLayer `core` — terraform/core on main. Deliberately the ONLY
    layer: core is the one workspace whose providers are AWS-only. stage-1 and
    prod-1 also carry cloudflare/grafana (token seeding, a promotion step) and
    google via keyless WIF, which only authenticates from GitHub Actions — an
    in-cluster runner can't plan those without minting a GCP SA key.
  * runner-creds ExternalSecret — AWS access key for `terraform plan` (state
    read + refresh), materialized from SM. The key belongs to the read-only
    `burrito` IAM user (terraform/core/burrito.tf), so the credential in the
    cluster structurally cannot apply — applies stay Dana-driven.
  * tailscale Ingress — the UI at burrito-prod.<tailnet>.ts.net.

The whole trial is plan-only: remediationStrategy.autoApply stays false (also
Burrito's default) on every layer, pinned by tests/unit/test_burrito.py.

Burrito CRs (TerraformRepository/TerraformLayer) are emitted via ApiObject —
one-off objects, so (like the Argo CRs in argocd.py) typed imports aren't
worth it.
"""

from __future__ import annotations

import cdk8s
import imports.io.external_secrets as esx
import imports.k8s as k8s
from constructs import Construct

BURRITO_API = "config.terraform.padok.cloud/v1alpha1"
# The tenant namespace (CRs + runner pods) — created by the chart, which reads
# it from k8s/burrito/values.yml. KEEP-IN-SYNC with the `tenants` entry there.
TENANT_NS = "burrito"
# The chart's own namespace (controller/server/datastore + the UI Service).
SYSTEM_NS = "burrito-system"
INFRA_HTTPS_URL = "https://github.com/adanalife/infra.git"
# KEEP-IN-SYNC with the repo-root .terraform-version.
TERRAFORM_VERSION = "1.15.2"
TAILNET_HOST = "burrito-prod"  # -> burrito-prod.<tailnet>.ts.net
RUNNER_SECRET = "burrito-aws-core"
# Seeded by hand in prod's SM (the account the cluster store reads) from the
# core-account `burrito` IAM user's key — see vault/infra/burrito.md.
ACCESS_KEY_SM_KEY = "/k8s/burrito/core-access-key-id"
SECRET_KEY_SM_KEY = "/k8s/burrito/core-secret-access-key"


class Burrito(Construct):
    def __init__(self, scope: Construct, id: str = "burrito"):
        super().__init__(scope, id)
        self._repository()
        self._layer()
        self._runner_external_secret()
        self._ui_ingress()

    def _repository(self):
        repo = cdk8s.ApiObject(
            self,
            "repository",
            api_version=BURRITO_API,
            kind="TerraformRepository",
            metadata={"name": "infra", "namespace": TENANT_NS},
        )
        repo.add_json_patch(
            cdk8s.JsonPatch.add(
                "/spec",
                {
                    "repository": {"url": INFRA_HTTPS_URL},
                    # terraform, not OpenTofu — propagates to every layer.
                    "terraform": {"enabled": True},
                },
            )
        )

    def _layer(self):
        layer = cdk8s.ApiObject(
            self,
            "layer-core",
            api_version=BURRITO_API,
            kind="TerraformLayer",
            metadata={"name": "core", "namespace": TENANT_NS},
        )
        layer.add_json_patch(
            cdk8s.JsonPatch.add(
                "/spec",
                {
                    "path": "terraform/core",
                    "branch": "main",
                    "terraform": {"version": TERRAFORM_VERSION},
                    "repository": {"name": "infra", "namespace": TENANT_NS},
                    # False is Burrito's default; declared so the trial's
                    # safety property is explicit — plan and report drift,
                    # never apply.
                    "remediationStrategy": {"autoApply": False},
                    "overrideRunnerSpec": {
                        # The S3 state backend declares no region; the runner
                        # supplies it like CI does.
                        "env": [{"name": "AWS_REGION", "value": "us-east-1"}],
                        "envFrom": [{"secretRef": {"name": RUNNER_SECRET}}],
                    },
                },
            )
        )

    def _runner_external_secret(self):
        # The runner's AWS credential (read-only `burrito` IAM user), shaped as
        # the AWS_* env vars terraform reads. Same cluster-store pattern as the
        # Argo repo keys.
        esx.ExternalSecret(
            self,
            "runner-secret",
            metadata={"name": RUNNER_SECRET, "namespace": TENANT_NS},
            spec=esx.ExternalSecretSpec(
                refresh_interval="1h",
                secret_store_ref=esx.ExternalSecretSpecSecretStoreRef(
                    name="aws-parameterstore-cluster",
                    kind=esx.ExternalSecretSpecSecretStoreRefKind.CLUSTER_SECRET_STORE,
                ),
                target=esx.ExternalSecretSpecTarget(
                    name=RUNNER_SECRET,
                    creation_policy=esx.ExternalSecretSpecTargetCreationPolicy.OWNER,
                ),
                data=[
                    esx.ExternalSecretSpecData(
                        secret_key="AWS_ACCESS_KEY_ID",
                        remote_ref=esx.ExternalSecretSpecDataRemoteRef(
                            key=ACCESS_KEY_SM_KEY
                        ),
                    ),
                    esx.ExternalSecretSpecData(
                        secret_key="AWS_SECRET_ACCESS_KEY",
                        remote_ref=esx.ExternalSecretSpecDataRemoteRef(
                            key=SECRET_KEY_SM_KEY
                        ),
                    ),
                ],
            ),
        )

    def _ui_ingress(self):
        # TLS terminates at the tailnet edge; forwards to burrito-server:80.
        # Same shape as Argo's tailnet UI Ingress (argocd.py _ui_ingress).
        k8s.KubeIngress(
            self,
            "ui-ingress",
            metadata=k8s.ObjectMeta(
                name="burrito-server-tailscale", namespace=SYSTEM_NS
            ),
            spec=k8s.IngressSpec(
                ingress_class_name="tailscale",
                default_backend=k8s.IngressBackend(
                    service=k8s.IngressServiceBackend(
                        name="burrito-server",
                        port=k8s.ServiceBackendPort(name="http"),
                    )
                ),
                tls=[k8s.IngressTls(hosts=[TAILNET_HOST])],
            ),
        )
