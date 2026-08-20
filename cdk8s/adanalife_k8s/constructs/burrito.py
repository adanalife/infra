"""Burrito trial config, authored in cdk8s. Synthesizes to dist/burrito.k8s.yaml
— a committed, golden-gated deploy unit applied (task k8s:prod:burrito:apply)
after the Burrito install (the `burrito` HelmComponent in helm_platform.py,
Argo-delivered via platform-argo). Burrito is the controller; these are the
objects that tell it what to plan:

  * TerraformRepository `infra` — the infra repo over anonymous HTTPS (public,
    so no deploy key — same as the obs/playout Argo sources).
  * One TerraformLayer per remote-state workspace (LAYERS below): core,
    platform, stage-1, prod-1. terraform/bootstrap is deliberately absent — its
    state is a file committed in the repo, and it pins `required_version
    ~> 0.13`, so there is nothing for a 1.x runner to plan.
  * One runner-creds ExternalSecret per layer, materialized from SM. core and
    platform get a ReadOnlyAccess key and so cannot be applied from here at
    all; stage-1 and prod-1 get the admin `burrito-apply` key, which is what
    lets a TerraformRun with action=apply against them succeed.

    That boundary is coarser than it looks. overrideRunnerSpec is per-LAYER,
    not per-action, so an appliable layer runs its hourly drift PLAN as an
    administrator too — no arrangement plans read-only and applies with write
    access on one layer. Making it finer means splitting the terraform state so
    the irreplaceable resources sit in a layer that keeps a read-only
    credential, which is the tracked follow-up. Until then core and platform
    are the workspaces whose apply path stays a workstation gesture, and
    stage-1/prod-1 are the ones where even a plan holds admin.
  * For stage-1/prod-1, a GCP credential-config ConfigMap + a projected
    ServiceAccount token: the google provider authenticates keyless by
    federating the cluster's own OIDC issuer (env-base/google.tf), so no GCP
    service account key exists.
  * an OIDC client-secret ExternalSecret for the server itself — the UI
    authenticates through Cloudflare Access (terraform/prod-1/burrito-oidc.tf),
    and this is the one auth setting the chart takes as an env var rather than
    a value.
  * tailscale Ingress — the UI at burrito-prod.<tailnet>.ts.net.
  * traefik Ingress — the same UI at burrito.prod.whereisdana.today, published
    by external-dns to the cluster's LAN endpoint, cert via the route53
    ClusterIssuer. Mirrors Argo's dual tailnet+LAN exposure (Burrito, like
    Argo, is a prod-level install governing the whole cluster's view, so it
    lives under the prod subdomain).

Each layer gets its own IAM user rather than sharing one, so a layer's blast
radius is its own workspace. The `platform` split is the load-bearing case: its
github provider reads the automation App's private key from SM, which every
other layer's user is explicitly denied (terraform/core/burrito.tf).

Credentials the providers need beyond AWS — cloudflare, grafana, tailscale —
are not seeded anywhere: those providers read their tokens from the env
account's Parameter Store, which ReadOnlyAccess already covers.

The whole trial is plan-only: remediationStrategy.autoApply stays false (also
Burrito's default) on every layer, pinned by tests/unit/test_burrito.py.

Burrito CRs (TerraformRepository/TerraformLayer) are emitted via ApiObject —
one-off objects, so (like the Argo CRs in argocd.py) typed imports aren't
worth it.
"""

from __future__ import annotations

import json
from dataclasses import dataclass

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
# Created by the chart (the `tenants[].serviceAccounts` entry in values.yml).
# Named on every runner because the projected token below is what GCP
# federates — its subject is this ServiceAccount.
RUNNER_SA = "burrito-runner"
INFRA_HTTPS_URL = "https://github.com/adanalife/infra.git"
# KEEP-IN-SYNC with the repo-root .terraform-version.
TERRAFORM_VERSION = "1.15.2"
TAILNET_HOST = "burrito-prod"  # -> burrito-prod.<tailnet>.ts.net
# LAN-reachable UI host, external-dns-published — same shape as
# argocd.prod.whereisdana.today (see argocd.py _lan_ingress).
LAN_HOST = "burrito.prod.whereisdana.today"
# The S3 state backend declares no region; runners supply it like CI does.
AWS_REGION = "us-east-1"

# Audience the runner's projected token is minted for, and the only one the
# WIF providers accept. KEEP-IN-SYNC with local.burrito_token_audience in
# terraform/modules/env-base/google.tf.
# The server's OIDC client secret, the one auth setting the chart takes as an
# env var rather than a value (k8s/burrito/values.yml carries the rest). Name
# matches the chart's own documented example.
OIDC_SECRET = "burrito-oidc-client-secret"
OIDC_SECRET_SM_KEY = "/k8s/burrito/oidc-client-secret"

GCP_TOKEN_AUDIENCE = "adanalife-burrito"
GCP_TOKEN_DIR = "/var/run/secrets/gcp"
GCP_CONFIG_DIR = "/etc/gcp"
GCP_CONFIG_FILE = "credential-config.json"


@dataclass(frozen=True)
class Layer:
    """A terraform workspace Burrito plans, and the credentials it needs.

    `sm_prefix` names the SM parameter pair holding the layer's AWS key —
    /k8s/burrito/<prefix>-access-key-id and -secret-access-key, seeded by hand
    into prod's Parameter Store (the account the cluster store reads) from the
    workspace's own `burrito_*` terraform outputs.

    `gcp_project`/`gcp_project_number` are set only for the workspaces carrying
    a google provider; they select the per-project WIF provider the runner
    trades its ServiceAccount token at.

    `appliable` swaps the read-only credential for the admin one, which is what
    lets a TerraformRun with action=apply succeed. It is not an apply-time-only
    switch: overrideRunnerSpec is per-layer, not per-action, so an appliable
    layer runs its hourly drift PLAN as an administrator too. That is the whole
    reason core and platform are left alone — see the module docstring.
    """

    name: str
    path: str
    sm_prefix: str
    gcp_project: str | None = None
    gcp_project_number: str | None = None
    appliable: bool = False

    @property
    def secret_name(self) -> str:
        suffix = "-apply" if self.appliable else ""
        return f"burrito-aws-{self.sm_prefix}{suffix}"

    @property
    def sm_key_prefix(self) -> str:
        """Which SM parameter pair backs this layer's credential — the apply
        user's key when the layer can apply, the read-only user's otherwise."""
        return f"{self.sm_prefix}-apply" if self.appliable else self.sm_prefix

    @property
    def wif_audience(self) -> str:
        return (
            f"//iam.googleapis.com/projects/{self.gcp_project_number}"
            "/locations/global/workloadIdentityPools/minipc/providers/minipc"
        )

    @property
    def plan_service_account(self) -> str:
        return f"burrito-plan@{self.gcp_project}.iam.gserviceaccount.com"


LAYERS = (
    Layer(name="core", path="terraform/core", sm_prefix="core"),
    Layer(name="platform", path="terraform/platform", sm_prefix="platform"),
    Layer(
        name="stage-1",
        path="terraform/stage-1",
        sm_prefix="stage",
        gcp_project="tripbot-stage",
        gcp_project_number="574760983858",
        appliable=True,
    ),
    Layer(
        name="prod-1",
        path="terraform/prod-1",
        sm_prefix="prod",
        gcp_project="tripbot-prod",
        gcp_project_number="876608406330",
        appliable=True,
    ),
)


class Burrito(Construct):
    def __init__(self, scope: Construct, id: str = "burrito"):
        super().__init__(scope, id)
        self._repository()
        for layer in LAYERS:
            self._layer(layer)
            self._runner_external_secret(layer)
            if layer.gcp_project:
                self._gcp_credential_config(layer)
        self._oidc_client_secret()
        self._ui_ingress()
        self._lan_ingress()

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

    def _layer(self, layer: Layer):
        obj = cdk8s.ApiObject(
            self,
            f"layer-{layer.name}",
            api_version=BURRITO_API,
            kind="TerraformLayer",
            metadata={"name": layer.name, "namespace": TENANT_NS},
        )
        obj.add_json_patch(
            cdk8s.JsonPatch.add(
                "/spec",
                {
                    "path": layer.path,
                    "branch": "main",
                    "terraform": {"version": TERRAFORM_VERSION},
                    "repository": {"name": "infra", "namespace": TENANT_NS},
                    # False is Burrito's default; declared so the trial's
                    # safety property is explicit — plan and report drift,
                    # never apply.
                    "remediationStrategy": {"autoApply": False},
                    "overrideRunnerSpec": self._runner_spec(layer),
                },
            )
        )

    def _runner_spec(self, layer: Layer) -> dict:
        spec = {
            "serviceAccountName": RUNNER_SA,
            "env": [{"name": "AWS_REGION", "value": AWS_REGION}],
            "envFrom": [{"secretRef": {"name": layer.secret_name}}],
        }
        if not layer.gcp_project:
            return spec

        # Keyless GCP: the kubelet mints a short-lived token for this pod's
        # ServiceAccount, the google client library trades it at STS for a
        # token impersonating the read-only burrito-plan SA. gcp_impersonate is
        # off for the same reason CI turns it off — the credential already IS
        # the delegated identity, so there is no second hop to make.
        spec["env"] += [
            {
                "name": "GOOGLE_APPLICATION_CREDENTIALS",
                "value": f"{GCP_CONFIG_DIR}/{GCP_CONFIG_FILE}",
            },
            {"name": "TF_VAR_gcp_impersonate", "value": "false"},
        ]
        spec["volumes"] = [
            {
                "name": "gcp-token",
                "projected": {
                    "sources": [
                        {
                            "serviceAccountToken": {
                                "audience": GCP_TOKEN_AUDIENCE,
                                "expirationSeconds": 3600,
                                "path": "token",
                            }
                        }
                    ]
                },
            },
            {
                "name": "gcp-credential-config",
                "configMap": {"name": self._config_map_name(layer)},
            },
        ]
        spec["volumeMounts"] = [
            {"name": "gcp-token", "mountPath": GCP_TOKEN_DIR, "readOnly": True},
            {
                "name": "gcp-credential-config",
                "mountPath": GCP_CONFIG_DIR,
                "readOnly": True,
            },
        ]
        return spec

    @staticmethod
    def _config_map_name(layer: Layer) -> str:
        return f"burrito-gcp-{layer.name}"

    def _gcp_credential_config(self, layer: Layer):
        # Google's external_account credential file: where to find the subject
        # token, which pool to exchange it at, and whose identity to assume.
        # Public config, no secret material — the token it points at is minted
        # per-pod by the kubelet.
        config = {
            "type": "external_account",
            "audience": layer.wif_audience,
            "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
            "token_url": "https://sts.googleapis.com/v1/token",
            "service_account_impersonation_url": (
                "https://iamcredentials.googleapis.com/v1/projects/-"
                f"/serviceAccounts/{layer.plan_service_account}:generateAccessToken"
            ),
            "credential_source": {
                "file": f"{GCP_TOKEN_DIR}/token",
                "format": {"type": "text"},
            },
        }
        k8s.KubeConfigMap(
            self,
            f"gcp-config-{layer.name}",
            metadata=k8s.ObjectMeta(
                name=self._config_map_name(layer), namespace=TENANT_NS
            ),
            data={GCP_CONFIG_FILE: json.dumps(config, indent=2)},
        )

    def _runner_external_secret(self, layer: Layer):
        # The runner's AWS credential (a ReadOnlyAccess IAM user), shaped as
        # the AWS_* env vars terraform reads. Same cluster-store pattern as the
        # Argo repo keys.
        esx.ExternalSecret(
            self,
            f"runner-secret-{layer.name}",
            metadata={"name": layer.secret_name, "namespace": TENANT_NS},
            spec=esx.ExternalSecretSpec(
                refresh_interval="1h",
                secret_store_ref=esx.ExternalSecretSpecSecretStoreRef(
                    name="aws-parameterstore-cluster",
                    kind=esx.ExternalSecretSpecSecretStoreRefKind.CLUSTER_SECRET_STORE,
                ),
                target=esx.ExternalSecretSpecTarget(
                    name=layer.secret_name,
                    creation_policy=esx.ExternalSecretSpecTargetCreationPolicy.OWNER,
                ),
                data=[
                    esx.ExternalSecretSpecData(
                        secret_key="AWS_ACCESS_KEY_ID",
                        remote_ref=esx.ExternalSecretSpecDataRemoteRef(
                            key=f"/k8s/burrito/{layer.sm_key_prefix}-access-key-id"
                        ),
                    ),
                    esx.ExternalSecretSpecData(
                        secret_key="AWS_SECRET_ACCESS_KEY",
                        remote_ref=esx.ExternalSecretSpecDataRemoteRef(
                            key=f"/k8s/burrito/{layer.sm_key_prefix}-secret-access-key"
                        ),
                    ),
                ],
            ),
        )

    def _oidc_client_secret(self):
        # Lives in the chart's namespace, not the tenant one: this is the
        # server's login, not a runner credential. Terraform owns the value
        # (terraform/prod-1/burrito-oidc.tf creates the Access application and
        # writes its secret straight to SM), so there is nothing to seed by
        # hand and rotation is an apply.
        #
        # The key IS the env var name — the chart mounts this Secret with
        # envFrom, so BURRITO_SERVER_OIDC_CLIENTSECRET is what reaches the
        # process.
        esx.ExternalSecret(
            self,
            "oidc-client-secret",
            metadata={"name": OIDC_SECRET, "namespace": SYSTEM_NS},
            spec=esx.ExternalSecretSpec(
                refresh_interval="1h",
                secret_store_ref=esx.ExternalSecretSpecSecretStoreRef(
                    name="aws-parameterstore-cluster",
                    kind=esx.ExternalSecretSpecSecretStoreRefKind.CLUSTER_SECRET_STORE,
                ),
                target=esx.ExternalSecretSpecTarget(
                    name=OIDC_SECRET,
                    creation_policy=esx.ExternalSecretSpecTargetCreationPolicy.OWNER,
                ),
                data=[
                    esx.ExternalSecretSpecData(
                        secret_key="BURRITO_SERVER_OIDC_CLIENTSECRET",
                        remote_ref=esx.ExternalSecretSpecDataRemoteRef(
                            key=OIDC_SECRET_SM_KEY
                        ),
                    ),
                ],
            ),
        )

    def _lan_ingress(self):
        # LAN-reachable UI at burrito.prod.whereisdana.today — the same shape
        # as Argo's traefik Ingress (argocd.py _lan_ingress): external-dns
        # publishes the record to the cluster's LAN endpoint; cert-manager
        # issues the cert via the cluster-scoped route53 issuer (burrito-system
        # has no namespaced Issuer). Reachable on-LAN directly, off-LAN via the
        # tailscale subnet route.
        k8s.KubeIngress(
            self,
            "lan-ingress",
            metadata=k8s.ObjectMeta(
                name="burrito-server-traefik",
                namespace=SYSTEM_NS,
                annotations={
                    "external-dns.alpha.kubernetes.io/hostname": LAN_HOST,
                    "cert-manager.io/cluster-issuer": "letsencrypt-route53",
                },
            ),
            spec=k8s.IngressSpec(
                ingress_class_name="traefik",
                tls=[
                    k8s.IngressTls(hosts=[LAN_HOST], secret_name="burrito-server-tls")
                ],
                rules=[
                    k8s.IngressRule(
                        host=LAN_HOST,
                        http=k8s.HttpIngressRuleValue(
                            paths=[
                                k8s.HttpIngressPath(
                                    path="/",
                                    path_type="Prefix",
                                    backend=k8s.IngressBackend(
                                        service=k8s.IngressServiceBackend(
                                            name="burrito-server",
                                            port=k8s.ServiceBackendPort(name="http"),
                                        )
                                    ),
                                )
                            ]
                        ),
                    )
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
