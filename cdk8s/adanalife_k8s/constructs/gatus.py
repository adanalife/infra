"""Gatus — the in-cluster endpoint prober.

Grafana Synthetic Monitoring (terraform/platform/grafana-synthetic-monitoring.tf)
probes the public endpoints from outside, but it is budget-capped and cannot reach
anything that only routes on the LAN. Gatus covers the inside: the always-on
data-plane services by their cluster DNS names, and the `*.prod.whereisdana.today`
traefik hosts the way a LAN client reaches them (DNS, traefik, TLS, backend), with
the certificate's remaining lifetime as a condition.

It dies with the minipc, so it is never the signal for "the house is down" — that
stays with Synthetic Monitoring. Its alerting is Grafana's: Gatus only evaluates
and exports `gatus_results_endpoint_success` (one series per endpoint) on
/metrics, which annotation autodiscovery scrapes and the `gatus-health` rule group
in grafana-alerts.tf pages on. No Gatus alerting providers are configured, so
there is one pager. Results persist in SQLite on a local-path claim, so the
dashboard's uptime history survives a restart; the series in Prometheus are the
long-term record.

Only always-on targets belong here. The per-platform apps (tripbot, playout,
onscreens, OBS, mediamtx) are scaled to zero by the console's mode switch and for
the platforms that aren't live, so a probe on them would read red by design;
their readiness probes and kube-state-metrics already cover them.

Dashboard: https://gatus.prod.whereisdana.today (LAN, or off-LAN via the tailnet
subnet route).
"""

from __future__ import annotations

import imports.k8s as k8s
import yaml
from constructs import Construct

from adanalife_k8s.naming import (
    CONFIG_HASH_ANNOTATION,
    config_hash,
    meta_labels,
    selector,
)

NAME = "gatus"
NAMESPACE = "gatus"
# Latest stable at add time; ghcr rather than Docker Hub, per the base-image ADR.
IMAGE = "ghcr.io/twin/gatus:v5.38.0"
PORT = 8080
LAN_HOST = "gatus.prod.whereisdana.today"
INTERVAL = "60s"
DATA_CLAIM = "gatus-data"
# cert-manager renews 30 days out, so under 14 days left means renewal is failing.
CERT_FLOOR = "[CERTIFICATE_EXPIRATION] > 336h"


def _tcp(name: str, group: str, host: str, port: int) -> dict:
    return {
        "name": name,
        "group": group,
        "url": f"tcp://{host}:{port}",
        "interval": INTERVAL,
        "conditions": ["[CONNECTED] == true"],
    }


def _lan(name: str, path: str = "/", extra: tuple[str, ...] = ()) -> dict:
    return {
        "name": name,
        "group": "lan-ingress",
        "url": f"https://{name}.prod.whereisdana.today{path}",
        "interval": INTERVAL,
        "conditions": ["[STATUS] == 200", CERT_FLOOR, *extra],
    }


ENDPOINTS = [
    _tcp("postgres", "data", "pg-rw.prod-1-data.svc.cluster.local", 5432),
    _tcp("nats", "data", "nats.prod-1-platform.svc.cluster.local", 4222),
    {
        "name": "tripbot-console",
        "group": "apps",
        "url": "http://tripbot-console.prod-1.svc.cluster.local:8080/health/ready",
        "interval": INTERVAL,
        "conditions": ["[STATUS] == 200", "[BODY].status == ok"],
    },
    {
        "name": "radio",
        "group": "apps",
        "url": "http://radio.prod-1.svc.cluster.local:8000/",
        "interval": INTERVAL,
        "conditions": ["[STATUS] == 200"],
    },
    # Unauthenticated answers: the console's readiness route is public, the
    # other UIs serve their login/landing page at /.
    _lan("console", "/health/ready", ("[BODY].status == ok",)),
    _lan("argocd"),
    _lan("burrito"),
    _lan("hubble"),
    _lan("argo-workflows"),
    _lan("gatus"),
]

CONFIG = {
    "metrics": True,
    "web": {"port": PORT},
    "storage": {"type": "sqlite", "path": "/data/data.db"},
    "ui": {"title": "adanalife: inside", "header": "adanalife (prod, in-cluster)"},
    "endpoints": ENDPOINTS,
}


class Gatus(Construct):
    """Gatus + its config, Service and LAN Ingress. Cluster-singleton in its own
    `gatus` namespace, delivered by a minipc-only Argo Application (see
    constructs/argocd.py)."""

    def __init__(self, scope: Construct, id: str = NAME):
        super().__init__(scope, id)
        labels = meta_labels(NAME, part_of="infra")
        sel = selector(NAME)
        config = {"config.yaml": yaml.safe_dump(CONFIG, sort_keys=False)}

        k8s.KubeConfigMap(
            self,
            "config",
            metadata=k8s.ObjectMeta(name=NAME, namespace=NAMESPACE, labels=labels),
            data=config,
        )

        container = k8s.Container(
            name=NAME,
            image=IMAGE,
            env=[k8s.EnvVar(name="GATUS_CONFIG_PATH", value="/config/config.yaml")],
            ports=[k8s.ContainerPort(name="http", container_port=PORT)],
            readiness_probe=k8s.Probe(
                http_get=k8s.HttpGetAction(
                    path="/health", port=k8s.IntOrString.from_string("http")
                ),
            ),
            security_context=k8s.SecurityContext(
                allow_privilege_escalation=False,
                run_as_non_root=True,
                run_as_user=65534,  # nobody
                read_only_root_filesystem=True,
                capabilities=k8s.Capabilities(drop=["ALL"]),
            ),
            resources=k8s.ResourceRequirements(
                requests={
                    "cpu": k8s.Quantity.from_string("10m"),
                    "memory": k8s.Quantity.from_string("32Mi"),
                },
                limits={"memory": k8s.Quantity.from_string("128Mi")},
            ),
            volume_mounts=[
                k8s.VolumeMount(name="config", mount_path="/config", read_only=True),
                k8s.VolumeMount(name="data", mount_path="/data"),
            ],
        )

        k8s.KubeDeployment(
            self,
            "deployment",
            metadata=k8s.ObjectMeta(name=NAME, namespace=NAMESPACE, labels=labels),
            spec=k8s.DeploymentSpec(
                replicas=1,
                # RWO claim, and SQLite wants one writer.
                strategy=k8s.DeploymentStrategy(type="Recreate"),
                selector=k8s.LabelSelector(match_labels=sel),
                template=k8s.PodTemplateSpec(
                    metadata=k8s.ObjectMeta(
                        labels=sel,
                        annotations={
                            "prometheus.io/scrape": "true",
                            "prometheus.io/port": str(PORT),
                            # Gatus reads its config once at startup.
                            CONFIG_HASH_ANNOTATION: config_hash(config),
                        },
                    ),
                    spec=k8s.PodSpec(
                        security_context=k8s.PodSecurityContext(
                            seccomp_profile=k8s.SeccompProfile(type="RuntimeDefault"),
                            # Group-own the claim so the non-root user can write.
                            fs_group=65534,
                        ),
                        containers=[container],
                        volumes=[
                            k8s.Volume(
                                name="config",
                                config_map=k8s.ConfigMapVolumeSource(name=NAME),
                            ),
                            k8s.Volume(
                                name="data",
                                persistent_volume_claim=k8s.PersistentVolumeClaimVolumeSource(
                                    claim_name=DATA_CLAIM
                                ),
                            ),
                        ],
                    ),
                ),
            ),
        )

        k8s.KubePersistentVolumeClaim(
            self,
            "data",
            metadata=k8s.ObjectMeta(
                name=DATA_CLAIM, namespace=NAMESPACE, labels=labels
            ),
            spec=k8s.PersistentVolumeClaimSpec(
                access_modes=["ReadWriteOnce"],
                storage_class_name="local-path",
                resources=k8s.ResourceRequirements(
                    requests={"storage": k8s.Quantity.from_string("1Gi")}
                ),
            ),
        )

        k8s.KubeService(
            self,
            "service",
            metadata=k8s.ObjectMeta(name=NAME, namespace=NAMESPACE, labels=labels),
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

        # Same shape as burrito.py's _lan_ingress: external-dns publishes the
        # LAN record, cert-manager issues via the cluster-scoped route53 issuer.
        k8s.KubeIngress(
            self,
            "lan-ingress",
            metadata=k8s.ObjectMeta(
                name=NAME,
                namespace=NAMESPACE,
                labels=labels,
                annotations={
                    "external-dns.alpha.kubernetes.io/hostname": LAN_HOST,
                    "cert-manager.io/cluster-issuer": "letsencrypt-route53",
                },
            ),
            spec=k8s.IngressSpec(
                ingress_class_name="traefik",
                tls=[k8s.IngressTls(hosts=[LAN_HOST], secret_name="gatus-tls")],
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
