"""VlcServer — the dashcam video pipeline (libvlc + RTSP + HTTP API).

Shared today (one instance per env), built against the same naming/config/eso
helpers as ObsInstance so a future per-platform split is `for p in platforms:
VlcServer(self, p, env)`. Reproduces k8s/apps/vlc-server/base + overlays:

  * RollingUpdate (readiness-gated; dashcam PVC is ReadOnlyMany so both pods can
    mount during the surge), seccomp + drop-ALL hardening, /health probes.
  * dashcam volume: NFS PVC (prod/stage, env.nfs_*) or hostPath (local/dev).
  * iGPU request on GPU envs; OTEL/Sentry envFrom from shared-secrets.
  * traefik Ingress (TLS on minipc) + optional Tailscale Ingress.
  * prod-only: the in-pod onscreens process re-exposed on :8081 (container +
    Service port) until the OBS cutover — env.vlc_inpod_onscreens. See #621.
"""

from __future__ import annotations

import imports.k8s as k8s
from constructs import Construct

from adanalife_k8s import appconfig, configmap
from adanalife_k8s.config import EnvConfig
from adanalife_k8s.naming import meta_labels, selector

NAME = "vlc-server"
MOUNT_PATH = "/opt/data/Dashcam/_all"

# Container ports (deployment.yaml order) vs Service ports (service.yaml order)
# — the legacy base lists them in different orders; reproduce both. onscreens
# (8081) is appended prod-only via vlc_inpod_onscreens.
_CONTAINER_PORTS = [("http", 8080), ("vnc", 5900), ("rtsp", 8554)]
_SERVICE_PORTS = [("http", 8080), ("rtsp", 8554), ("vnc", 5900)]

# Constant base ConfigMap literals (kustomization configMapGenerator base set).
_BASE_CONFIG = {
    "DISPLAY": ":0.0",
    "XDG_RUNTIME_DIR": "/root/.cache/xdgr",
    "FONTCONFIG_PATH": "/etc/fonts",
    "VLC_SERVER_HOST": "vlc-server:8080",
}


class VlcServer(Construct):
    def __init__(self, scope: Construct, *, env: EnvConfig):
        super().__init__(scope, NAME)
        ns = env.namespace or None
        labels = meta_labels(NAME)
        sel = selector(NAME)

        container_ports = list(_CONTAINER_PORTS)
        service_ports = list(_SERVICE_PORTS)
        if env.vlc_inpod_onscreens:
            container_ports.append(("onscreens", 8081))
            service_ports.append(("onscreens", 8081))

        # --- ConfigMap (stable name + content-hash annotation) ---
        data = dict(_BASE_CONFIG)
        if appconfig.uses_local_stubs(env):
            data.update(appconfig.local_stubs())
        data.update(appconfig.telemetry_config(env))
        if env.vlc_inpod_onscreens:
            data["NATS_URL"] = env.nats_url
        cfg_hash = configmap.config_map(
            self,
            "config",
            name=f"{NAME}-config",
            namespace=ns,
            labels=labels,
            data=data,
        )

        # --- dashcam volume (nfs PVC | hostPath) ---
        # The NFS PV/PVC are NOT emitted here — they're stateful, so they live in
        # DataChart (emit_dashcam_volume), separate from this stateless Deployment
        # so app churn can't disturb them. This just references the PVC by name.
        if env.dashcam_mode == "nfs":
            volume = k8s.Volume(
                name="dashcam",
                persistent_volume_claim=k8s.PersistentVolumeClaimVolumeSource(
                    claim_name="vlc-dashcam", read_only=True
                ),
            )
        else:
            volume = k8s.Volume(
                name="dashcam",
                host_path=k8s.HostPathVolumeSource(
                    path="/host/dashcam", type="Directory"
                ),
            )

        # --- resources (+ iGPU on GPU envs) ---
        requests = {
            "cpu": k8s.Quantity.from_string("200m"),
            "memory": k8s.Quantity.from_string("512Mi"),
        }
        limits = {"memory": k8s.Quantity.from_string("2Gi")}
        if env.gpu:
            requests["gpu.intel.com/i915"] = k8s.Quantity.from_string("1")
            limits["gpu.intel.com/i915"] = k8s.Quantity.from_string("1")

        container = k8s.Container(
            name=NAME,
            image=f"adanalife/vlc:{env.image_tag}",
            image_pull_policy="Always",
            security_context=k8s.SecurityContext(
                allow_privilege_escalation=False,
                capabilities=k8s.Capabilities(drop=["ALL"]),
            ),
            ports=[
                k8s.ContainerPort(name=n, container_port=p) for n, p in container_ports
            ],
            env_from=[
                k8s.EnvFromSource(
                    config_map_ref=k8s.ConfigMapEnvSource(name=f"{NAME}-config")
                ),
                k8s.EnvFromSource(
                    secret_ref=k8s.SecretEnvSource(
                        name="sentry-vlc-server", optional=False
                    )
                ),
                k8s.EnvFromSource(
                    secret_ref=k8s.SecretEnvSource(
                        name="grafana-cloud-otlp", optional=False
                    )
                ),
            ],
            liveness_probe=k8s.Probe(
                http_get=k8s.HttpGetAction(
                    path="/health/live", port=k8s.IntOrString.from_string("http")
                ),
                initial_delay_seconds=15,
                period_seconds=30,
                timeout_seconds=5,
            ),
            readiness_probe=k8s.Probe(
                http_get=k8s.HttpGetAction(
                    path="/health/ready", port=k8s.IntOrString.from_string("http")
                ),
                initial_delay_seconds=5,
                period_seconds=10,
            ),
            resources=k8s.ResourceRequirements(requests=requests, limits=limits),
            volume_mounts=[
                k8s.VolumeMount(name="dashcam", mount_path=MOUNT_PATH, read_only=True)
            ],
        )

        k8s.KubeDeployment(
            self,
            "deployment",
            metadata=k8s.ObjectMeta(name=NAME, namespace=ns, labels=labels),
            spec=k8s.DeploymentSpec(
                replicas=1,
                strategy=k8s.DeploymentStrategy(
                    type="RollingUpdate",
                    rolling_update=k8s.RollingUpdateDeployment(
                        max_surge=k8s.IntOrString.from_number(1),
                        max_unavailable=k8s.IntOrString.from_number(0),
                    ),
                ),
                selector=k8s.LabelSelector(match_labels=sel),
                template=k8s.PodTemplateSpec(
                    metadata=k8s.ObjectMeta(
                        labels=sel, annotations=configmap.pod_annotations(cfg_hash)
                    ),
                    spec=k8s.PodSpec(
                        security_context=k8s.PodSecurityContext(
                            seccomp_profile=k8s.SeccompProfile(type="RuntimeDefault")
                        ),
                        containers=[container],
                        volumes=[volume],
                    ),
                ),
            ),
        )

        # --- Service ---
        svc_ports = [
            k8s.ServicePort(name=n, port=p, target_port=k8s.IntOrString.from_string(n))
            for n, p in service_ports
        ]
        k8s.KubeService(
            self,
            "service",
            metadata=k8s.ObjectMeta(name=NAME, namespace=ns, labels=labels),
            spec=k8s.ServiceSpec(type="ClusterIP", selector=sel, ports=svc_ports),
        )

        # --- host-access LoadBalancer (k3d-only convenience: local + dev, which
        # extends local). Overlay-added, so no metadata labels (matches render). ---
        if appconfig.uses_local_stubs(env):
            k8s.KubeService(
                self,
                "host-access",
                metadata=k8s.ObjectMeta(name=f"{NAME}-host", namespace=ns),
                spec=k8s.ServiceSpec(
                    type="LoadBalancer",
                    selector=sel,
                    ports=[
                        k8s.ServicePort(
                            name="vnc",
                            port=5903,
                            target_port=k8s.IntOrString.from_string("vnc"),
                        ),
                        k8s.ServicePort(
                            name="rtsp",
                            port=8554,
                            target_port=k8s.IntOrString.from_string("rtsp"),
                        ),
                    ],
                ),
            )

        # --- Ingress(es) — only where the env publishes DNS. Overlay-added, so
        # no metadata labels (the base `labels:` directive never touched them). ---
        if env.dns_base:
            self._ingress(env, ns)
        if env.tailscale and env.dns_base:
            self._tailscale_ingress(env, ns)

    # ---- helpers ----
    def _ingress(self, env: EnvConfig, ns):
        host = f"vlc.{env.dns_base}"
        ann = {"external-dns.alpha.kubernetes.io/hostname": host}
        if env.tls:
            ann["cert-manager.io/issuer"] = "letsencrypt-route53"
        backend = k8s.IngressBackend(
            service=k8s.IngressServiceBackend(
                name=NAME, port=k8s.ServiceBackendPort(name="http")
            )
        )
        k8s.KubeIngress(
            self,
            "ingress",
            metadata=k8s.ObjectMeta(name=NAME, namespace=ns, annotations=ann),
            spec=k8s.IngressSpec(
                ingress_class_name="traefik",
                tls=[k8s.IngressTls(hosts=[host], secret_name="vlc-tls")]
                if env.tls
                else None,
                rules=[
                    k8s.IngressRule(
                        host=host,
                        http=k8s.HttpIngressRuleValue(
                            paths=[
                                k8s.HttpIngressPath(
                                    path="/", path_type="Prefix", backend=backend
                                )
                            ]
                        ),
                    )
                ],
            ),
        )

    def _tailscale_ingress(self, env: EnvConfig, ns):
        short = env.dns_base.split(".")[0]  # prod / stage / dev
        k8s.KubeIngress(
            self,
            "ts-ingress",
            metadata=k8s.ObjectMeta(name=f"{NAME}-ts", namespace=ns),
            spec=k8s.IngressSpec(
                ingress_class_name="tailscale",
                default_backend=k8s.IngressBackend(
                    service=k8s.IngressServiceBackend(
                        name=NAME, port=k8s.ServiceBackendPort(number=8080)
                    )
                ),
                tls=[k8s.IngressTls(hosts=[f"vlc-{short}"])],
            ),
        )


def emit_dashcam_volume(scope: Construct, env: EnvConfig) -> None:
    """The dashcam NFS PV + PVC — a *stateful* pair, emitted into DataChart (not
    VlcServer) so the stateless vlc Deployment can churn without disturbing them.
    No-op on hostPath envs (local/dev), where the dashcam volume is an inline
    hostPath with no separate object. The PV is Retain — the corpus lives on the
    external NFS server, so even deleting the PVC doesn't lose data."""
    if env.dashcam_mode != "nfs":
        return
    ns = env.namespace or None
    # Static NFS PV (cluster-scoped) bound 1:1 to the PVC via volumeName +
    # storageClassName "". Stage shares prod's export read-only but needs its own
    # PV name (PVs bind 1:1) — env.nfs_pv_name.
    k8s.KubePersistentVolume(
        scope,
        "dashcam-pv",
        metadata=k8s.ObjectMeta(name=env.nfs_pv_name),
        spec=k8s.PersistentVolumeSpec(
            capacity={"storage": k8s.Quantity.from_string("1Ti")},
            access_modes=["ReadOnlyMany"],
            persistent_volume_reclaim_policy="Retain",
            storage_class_name="",
            nfs=k8s.NfsVolumeSource(
                server=env.nfs_server, path=env.nfs_path, read_only=True
            ),
        ),
    )
    k8s.KubePersistentVolumeClaim(
        scope,
        "dashcam-pvc",
        metadata=k8s.ObjectMeta(name="vlc-dashcam", namespace=ns),
        spec=k8s.PersistentVolumeClaimSpec(
            access_modes=["ReadOnlyMany"],
            storage_class_name="",
            volume_name=env.nfs_pv_name,
            resources=k8s.ResourceRequirements(
                requests={"storage": k8s.Quantity.from_string("1Ti")}
            ),
        ),
    )
