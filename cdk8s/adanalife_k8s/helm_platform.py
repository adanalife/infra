"""Platform Helm layer (Phase 3): the in-cluster platform stack wrapped in
`cdk8s.Helm`, which renders each chart via `helm template` at synth time.

Replaces the imperative `helm upgrade --install` sequence in `k8s:<env>:platform:up`
with declarative, **version-pinned** charts. Reuses the existing
`k8s/<component>/values*.yml` files verbatim (passed through with `-f`), so this
is a tooling change, not a values rewrite.

Two deploy units (mirrors the legacy split):
  * `PlatformChart(cluster)`  — the cluster-scoped platform (cilium, ESO, traefik,
    cert-manager, node-exporter, k8s-monitoring, tailscale-operator).
  * `PlatformEnvChart(env)`   — the per-env-platform pieces that live in the
    `<env>-platform` namespace (external-dns, NATS), with the LAN IP injected
    from `EnvConfig` (replacing the gitignored `values.local.yml`).

Version pins captured 2026-06-02 from the chart repos (the plan calls for pinning
the several charts that were deploying at floating latest). Bump deliberately per
[[use-latest-stable-when-adding]]; re-capture from a live `helm list -A` before a
cutover to confirm they match what's deployed.

The kustomize-only platform bits (local-path-provisioner, intel-gpu-plugin,
intel-xpu-manager, the ESO cluster-store, cert-manager ClusterIssuers) are NOT
Helm charts — they stay kustomize-applied as today; see the notes in
`PlatformChart`. Ordering (Cilium first, local-path before PVCs, ESO before
ExternalSecrets, cert-manager CRDs before Issuers) is enforced by applying the
platform chart before apps, exactly as the legacy task ordering did.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from cdk8s import Chart, Helm
from constructs import Construct

from adanalife_k8s.config import EnvConfig

# Path to the legacy values files, relative to the synth cwd (infra/cdk8s/).
K8S = "../k8s"

# --- Chart repos ---
REPOS = {
    "external-secrets": "https://charts.external-secrets.io",
    "traefik": "https://traefik.github.io/charts",
    "external-dns": "https://kubernetes-sigs.github.io/external-dns/",
    "jetstack": "https://charts.jetstack.io",
    "grafana": "https://grafana.github.io/helm-charts",
    "prometheus-community": "https://prometheus-community.github.io/helm-charts",
    "cilium": "https://helm.cilium.io",
    "nats": "https://nats-io.github.io/k8s/helm/charts/",
    "tailscale": "https://pkgs.tailscale.com/helmcharts",
}

# --- Version pins (captured 2026-06-02 from the repos above, and CONFIRMED
# against the live minipc: cert-manager v1.20.2, traefik 40.2.0,
# external-secrets 2.5.0, nats 2.14.0, external-dns 1.21.1,
# prometheus-node-exporter 4.55.0 (via helm.sh/chart labels) and
# k8s-monitoring 4.1.3 (via `helm list`) all match what's pinned here. cilium /
# tailscale-operator don't surface the umbrella chart label, but their live
# subcharts/values are consistent with these.) ---
VERSIONS = {
    "external-secrets": "2.5.0",
    "traefik": "40.2.0",
    "external-dns": "1.21.1",
    "cert-manager": "v1.20.2",
    "k8s-monitoring": "4.1.3",
    "prometheus-node-exporter": "4.55.0",
    "cilium": "1.19.4",
    "nats": "2.14.0",            # already pinned in the legacy task
    "tailscale-operator": "1.98.3",  # already pinned in the legacy task
}


@dataclass(frozen=True)
class HelmComponent:
    """One Helm release: chart coords + the legacy value files to feed it."""
    release: str          # helm release name (matches the live release)
    repo_key: str         # key into REPOS
    chart: str            # bare chart name (repo is passed separately)
    version_key: str      # key into VERSIONS
    namespace: str
    value_files: tuple[str, ...] = ()   # -f paths under K8S
    values: dict = field(default_factory=dict)  # extra inline overrides (e.g. LAN IP)

    def emit(self, scope: Construct) -> Helm:
        flags = ["--namespace", self.namespace]
        for vf in self.value_files:
            flags += ["-f", f"{K8S}/{vf}"]
        return Helm(scope, self.release,
                    chart=self.chart, repo=REPOS[self.repo_key],
                    version=VERSIONS[self.version_key],
                    release_name=self.release, namespace=self.namespace,
                    helm_flags=flags, values=self.values or {})


class PlatformChart(Chart):
    """Cluster-scoped platform stack for one cluster (`minipc` | `bees`).

    Excludes the per-env-platform charts (external-dns, NATS) — those vary by
    env namespace and live in PlatformEnvChart. Also excludes the kustomize-only
    components, which stay `kubectl apply -k`:
      * local-path-provisioner  (k8s/local-path-provisioner/<env>)
      * intel-gpu-plugin / intel-xpu-manager  (k8s/intel-*/<env>) — minipc
      * ESO cluster-store  (k8s/external-secrets/cluster-store)
      * cert-manager app-issuers  (emitted per-env by AppsChart already)
    """

    def __init__(self, scope: Construct, id: str, *, cluster: str, env: EnvConfig,
                 skip_monitoring: bool = False):
        super().__init__(scope, id)
        minipc = cluster == "minipc"

        components: list[HelmComponent] = []
        if minipc:
            # Cilium first — CNI + kube-proxy replacement; nothing schedules
            # until it's up (Talos installs neither).
            components.append(HelmComponent(
                "cilium", "cilium", "cilium", "cilium", "kube-system",
                value_files=("cilium/values.yml",)))

        components.append(HelmComponent(
            "external-secrets", "external-secrets", "external-secrets",
            "external-secrets", "external-secrets",
            value_files=("external-secrets/values.yml",)))

        if minipc:
            components.append(HelmComponent(
                "tailscale-operator", "tailscale", "tailscale-operator",
                "tailscale-operator", "tailscale",
                value_files=("tailscale-operator/values.yml",)))

        # traefik on the mini-PC runs hostNetwork and stamps the LAN IP into
        # Ingress status (replaces values.local.yml's ingressEndpoint.ip).
        traefik_files = ["traefik/values.yml"]
        traefik_values: dict = {}
        if minipc:
            traefik_files.append("traefik/values.prod-1.yml")
            traefik_values = {"providers": {"kubernetesIngress": {
                "ingressEndpoint": {"ip": env.lan_ip}}}}
        components.append(HelmComponent(
            "traefik", "traefik", "traefik", "traefik", "kube-system",
            value_files=tuple(traefik_files), values=traefik_values))

        components.append(HelmComponent(
            "cert-manager", "jetstack", "cert-manager", "cert-manager", "kube-system",
            value_files=(f"cert-manager/{env.name}/config.yml",)))

        components.append(HelmComponent(
            "node-exporter", "prometheus-community", "prometheus-node-exporter",
            "prometheus-node-exporter", "monitoring-host",
            value_files=("monitoring/node-exporter/values.yml",)))

        # k8s-monitoring 4.1.3 is confirmed live on the minipc (prod renders + the
        # pin matches `helm list`). But dev's values.yml was authored for the
        # bees cluster's OLDER deployed chart and trips the chart's
        # collector-validation under 4.1.3. Until that cluster's live version is
        # captured (it's on a separate box) and pinned, dev monitoring is skipped
        # here rather than guessed — it stays on the legacy
        # `task k8s:dev:platform:up` helm install. prod/stage are unaffected.
        if not skip_monitoring:
            components.append(HelmComponent(
                "k8s-monitoring", "grafana", "k8s-monitoring", "k8s-monitoring", "monitoring",
                value_files=(f"monitoring/{env.name}/values.yml",)))

        for comp in components:
            comp.emit(self)


class PlatformEnvChart(Chart):
    """Per-env-platform charts in the `<env>-platform` namespace: external-dns
    (publishes the env's Route53 zone to the LAN IP) and NATS (the pubsub bus).
    Separate from PlatformChart so stage + prod can co-tenant one cluster with
    isolated platform namespaces."""

    def __init__(self, scope: Construct, id: str, *, env: EnvConfig):
        super().__init__(scope, id)
        platform_ns = f"{env.name}-platform"
        # dev keeps external-dns in kube-system (legacy); minipc envs use the
        # env-platform namespace so the app namespace stays pod-clean.
        edns_ns = platform_ns if env.cluster == "minipc" else "kube-system"
        # Stage's external-dns release is named external-dns-stage (cluster-scoped
        # RBAC can't collide with prod's external-dns on the shared cluster).
        edns_release = "external-dns-stage" if env.name == "stage-1" else "external-dns"

        HelmComponent(
            edns_release, "external-dns", "external-dns", "external-dns", edns_ns,
            value_files=(f"external-dns/{env.name}/config.yml",),
            # LAN IP as the default record target (replaces values.local.yml's
            # --default-targets), injected from config instead of a gitignored file.
            values={"extraArgs": [f"--default-targets={env.lan_ip}"]},
        ).emit(self)

        HelmComponent(
            "nats", "nats", "nats", "nats", platform_ns,
            value_files=("nats/values.yml", f"nats/{env.name}/values.yml"),
        ).emit(self)
