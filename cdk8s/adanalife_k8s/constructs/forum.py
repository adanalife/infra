"""The forum — a Rails message board (github.com/b3s/b3s) with its own Postgres.

Upstream publishes no public image and hardcodes its own hostnames, so:

  * the image is built from a pinned upstream commit by
    .github/workflows/forum-image.yml — IMAGE's tag is that commit;
  * a ConfigMap-mounted Rails initializer admits HOST for requests, Action
    Cable origins and mailer links.

Nothing here reads Parameter Store. CNPG generates the database password
(the `pg-app` Secret) and ESO's Password generator mints SECRET_KEY_BASE once.
There is no RAILS_MASTER_KEY: without it Rails reads upstream's encrypted
credentials as empty, which leaves the S3 storage layer, Postmark and Sentry
off. Uploads live on the storage claim alone and no mail is sent.

Rails wants four databases (primary, plus Solid Cable / Cache / Queue). The
primary is the cluster's bootstrap database; the other three are CNPG Database
objects owned by the same role.

The first account to sign up becomes the admin.

https://forum.prod.whereisdana.today (LAN, or off-LAN via the tailnet subnet
route).
"""

from __future__ import annotations

import cdk8s
import imports.k8s as k8s
from constructs import Construct

from adanalife_k8s.constructs.cnpg import _IMAGE as PG_IMAGE
from adanalife_k8s.naming import (
    CONFIG_HASH_ANNOTATION,
    config_hash,
    meta_labels,
    selector,
)

NAME = "forum"
NAMESPACE = "forum"
# The tag is the upstream commit; a unit test holds it equal to the workflow's
# UPSTREAM_REF.
IMAGE = "ghcr.io/adanalife/forum:864b251083ba38cf5cc8af10b0189facd257c816"
PORT = 8080
HOST = "forum.prod.whereisdana.today"
STORAGE_CLAIM = "forum-storage"
SECRET_KEY_SECRET = "forum-secret-key-base"
# The image's `rails` user.
UID = 1000

PG_CLUSTER = "pg"
# CNPG names the generated app-user Secret <cluster>-app.
PG_SECRET = f"{PG_CLUSTER}-app"
DB = "forum"
EXTRA_DATABASES = ("cable", "cache", "queue")
# Deleting the claims must not delete a forum's posts and uploads.
STORAGE_CLASS = "local-path-retain"

# Sorts after upstream's initializers, so its mailer host wins.
INITIALIZER = "zz_host.rb"
INITIALIZER_RB = f"""\
Rails.application.configure do
  config.hosts += ["{HOST}"]
  config.action_cable.allowed_request_origins = ["https://{HOST}"]
  config.action_mailer.default_url_options = {{ host: "{HOST}", protocol: "https" }}
end
"""


def _secret_env(name: str, secret: str, key: str) -> k8s.EnvVar:
    return k8s.EnvVar(
        name=name,
        value_from=k8s.EnvVarSource(
            secret_key_ref=k8s.SecretKeySelector(name=secret, key=key)
        ),
    )


def _obj(scope: Construct, id: str, api_version: str, kind: str, name: str, spec: dict):
    obj = cdk8s.ApiObject(
        scope,
        id,
        api_version=api_version,
        kind=kind,
        metadata={
            "name": name,
            "namespace": NAMESPACE,
            "labels": meta_labels(NAME, part_of="infra"),
        },
    )
    obj.add_json_patch(cdk8s.JsonPatch.add("/spec", spec))


class Forum(Construct):
    """The forum, its Postgres, Service and LAN Ingress. Cluster-singleton in
    its own `forum` namespace, delivered by a minipc-only Argo Application (see
    constructs/argocd.py)."""

    def __init__(self, scope: Construct, id: str = NAME):
        super().__init__(scope, id)
        labels = meta_labels(NAME, part_of="infra")
        sel = selector(NAME)
        meta = k8s.ObjectMeta(name=NAME, namespace=NAMESPACE, labels=labels)

        # shortcut: no WAL archive or backup, add a barman ObjectStore (as
        # constructs/cnpg.py does) before the forum holds anything worth keeping.
        _obj(
            self,
            "pg",
            "postgresql.cnpg.io/v1",
            "Cluster",
            PG_CLUSTER,
            {
                "instances": 1,
                "imageName": PG_IMAGE,
                "storage": {"size": "5Gi", "storageClass": STORAGE_CLASS},
                "resources": {
                    "requests": {"cpu": "50m", "memory": "128Mi"},
                    "limits": {"memory": "512Mi"},
                },
                "bootstrap": {"initdb": {"database": DB, "owner": DB}},
            },
        )
        for db in EXTRA_DATABASES:
            _obj(
                self,
                f"db-{db}",
                "postgresql.cnpg.io/v1",
                "Database",
                f"{DB}-{db}",
                {"name": f"{DB}_{db}", "owner": DB, "cluster": {"name": PG_CLUSTER}},
            )

        # Generated once and never rotated: a new value signs every session out.
        _obj(
            self,
            "secret-key-generator",
            "generators.external-secrets.io/v1alpha1",
            "Password",
            SECRET_KEY_SECRET,
            {
                "length": 64,
                "symbols": 0,
                "allowRepeat": True,
                "noUpper": False,
                "secretKeys": ["SECRET_KEY_BASE"],
            },
        )
        _obj(
            self,
            "secret-key",
            "external-secrets.io/v1",
            "ExternalSecret",
            SECRET_KEY_SECRET,
            {
                "refreshPolicy": "CreatedOnce",
                "target": {"name": SECRET_KEY_SECRET},
                "dataFrom": [
                    {
                        "sourceRef": {
                            "generatorRef": {
                                "apiVersion": "generators.external-secrets.io/v1alpha1",
                                "kind": "Password",
                                "name": SECRET_KEY_SECRET,
                            }
                        }
                    }
                ],
            },
        )

        config = {INITIALIZER: INITIALIZER_RB}
        k8s.KubeConfigMap(self, "config", metadata=meta, data=config)

        def probe(**kwargs) -> k8s.Probe:
            return k8s.Probe(
                http_get=k8s.HttpGetAction(
                    path="/up", port=k8s.IntOrString.from_string("http")
                ),
                **kwargs,
            )

        container = k8s.Container(
            name=NAME,
            image=IMAGE,
            env=[
                _secret_env("DATABASE_URL", PG_SECRET, "uri"),
                _secret_env("PG_PASSWORD", PG_SECRET, "password"),
                *(
                    k8s.EnvVar(
                        name=f"{db.upper()}_DATABASE_URL",
                        value=f"postgresql://{DB}:$(PG_PASSWORD)@{PG_CLUSTER}-rw:5432/{DB}_{db}",
                    )
                    for db in EXTRA_DATABASES
                ),
                _secret_env("SECRET_KEY_BASE", SECRET_KEY_SECRET, "SECRET_KEY_BASE"),
                # One container: the job workers run inside Puma.
                k8s.EnvVar(name="SOLID_QUEUE_IN_PUMA", value="1"),
            ],
            ports=[k8s.ContainerPort(name="http", container_port=PORT)],
            # The entrypoint loads or migrates four schemas before anything
            # listens; allow it five minutes.
            startup_probe=probe(period_seconds=10, failure_threshold=30),
            readiness_probe=probe(),
            # nginx is PID 1 and Puma its background sibling, so a dead Puma
            # does not exit the container.
            liveness_probe=probe(period_seconds=30),
            security_context=k8s.SecurityContext(
                allow_privilege_escalation=False,
                run_as_non_root=True,
                run_as_user=UID,
                capabilities=k8s.Capabilities(drop=["ALL"]),
            ),
            resources=k8s.ResourceRequirements(
                requests={
                    "cpu": k8s.Quantity.from_string("50m"),
                    "memory": k8s.Quantity.from_string("256Mi"),
                },
                limits={"memory": k8s.Quantity.from_string("1Gi")},
            ),
            volume_mounts=[
                k8s.VolumeMount(
                    name="config",
                    mount_path=f"/rails/config/initializers/{INITIALIZER}",
                    sub_path=INITIALIZER,
                    read_only=True,
                ),
                # Upstream's only storage layer once S3 is off. It is declared
                # a cache, and Dis never evicts a file no other layer holds.
                k8s.VolumeMount(name="storage", mount_path="/rails/storage/dis-cache"),
            ],
        )

        k8s.KubeDeployment(
            self,
            "deployment",
            metadata=meta,
            spec=k8s.DeploymentSpec(
                replicas=1,
                # RWO claim.
                strategy=k8s.DeploymentStrategy(type="Recreate"),
                selector=k8s.LabelSelector(match_labels=sel),
                template=k8s.PodTemplateSpec(
                    metadata=k8s.ObjectMeta(
                        labels=sel,
                        annotations={CONFIG_HASH_ANNOTATION: config_hash(config)},
                    ),
                    spec=k8s.PodSpec(
                        security_context=k8s.PodSecurityContext(
                            seccomp_profile=k8s.SeccompProfile(type="RuntimeDefault"),
                            fs_group=UID,
                        ),
                        containers=[container],
                        volumes=[
                            k8s.Volume(
                                name="config",
                                config_map=k8s.ConfigMapVolumeSource(name=NAME),
                            ),
                            k8s.Volume(
                                name="storage",
                                persistent_volume_claim=k8s.PersistentVolumeClaimVolumeSource(
                                    claim_name=STORAGE_CLAIM
                                ),
                            ),
                        ],
                    ),
                ),
            ),
        )

        k8s.KubePersistentVolumeClaim(
            self,
            "storage",
            metadata=k8s.ObjectMeta(
                name=STORAGE_CLAIM, namespace=NAMESPACE, labels=labels
            ),
            spec=k8s.PersistentVolumeClaimSpec(
                access_modes=["ReadWriteOnce"],
                storage_class_name=STORAGE_CLASS,
                resources=k8s.ResourceRequirements(
                    requests={"storage": k8s.Quantity.from_string("5Gi")}
                ),
            ),
        )

        k8s.KubeService(
            self,
            "service",
            metadata=meta,
            spec=k8s.ServiceSpec(
                selector=sel,
                ports=[
                    k8s.ServicePort(
                        name="http",
                        port=PORT,
                        target_port=k8s.IntOrString.from_string("http"),
                    )
                ],
            ),
        )

        # Same shape as gatus.py's: external-dns publishes the LAN record,
        # cert-manager issues via the cluster-scoped route53 issuer.
        k8s.KubeIngress(
            self,
            "lan-ingress",
            metadata=k8s.ObjectMeta(
                name=NAME,
                namespace=NAMESPACE,
                labels=labels,
                annotations={
                    "external-dns.alpha.kubernetes.io/hostname": HOST,
                    "cert-manager.io/cluster-issuer": "letsencrypt-route53",
                },
            ),
            spec=k8s.IngressSpec(
                ingress_class_name="traefik",
                tls=[k8s.IngressTls(hosts=[HOST], secret_name="forum-tls")],
                rules=[
                    k8s.IngressRule(
                        host=HOST,
                        http=k8s.HttpIngressRuleValue(
                            paths=[
                                k8s.HttpIngressPath(
                                    path="/",
                                    path_type="Prefix",
                                    backend=k8s.IngressBackend(
                                        service=k8s.IngressServiceBackend(
                                            name=NAME,
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
