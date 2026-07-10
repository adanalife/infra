"""Platform Helm layer: the in-cluster platform stack wrapped in
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

Version pins captured 2026-06-02 from the chart repos. Bump deliberately;
re-capture from a live `helm list -A` before a cutover to confirm they match
what's deployed.

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
    "metrics-server": "https://kubernetes-sigs.github.io/metrics-server/",
    "nats": "https://nats-io.github.io/k8s/helm/charts/",
    "tailscale": "https://pkgs.tailscale.com/helmcharts",
    "argo": "https://argoproj.github.io/argo-helm",
    "cloudnative-pg": "https://cloudnative-pg.github.io/charts",
    # OCI registry (no scheme) — the ARC charts. Argo renders these in-cluster;
    # cdk8s.Helm can't `helm template` an OCI ref, so the ARC components are
    # Argo-only (never fed to PlatformChart). See arc_components below.
    "actions-runner": "ghcr.io/actions/actions-runner-controller-charts",
}

# --- Version pins, RE-CAPTURED 2026-06-10 from the live minipc (`helm list -A`)
# so adoption is pin == deployed (no up/down-grade on first sync). The
# legacy platform tasks install ESO / cert-manager / node-exporter /
# k8s-monitoring WITHOUT --version (floating latest), so they drift up over time;
# re-capture before each adoption pass. Deltas since the 2026-06-02 capture:
# external-secrets 2.5.0 -> 2.6.0, k8s-monitoring 4.1.3 -> 4.1.4 (both floated up).
# All others match live: cert-manager v1.20.2, node-exporter 4.55.0, nats 2.14.0,
# tailscale-operator 1.98.3, argo-cd 9.5.17 (+ the excluded traefik 40.2.0 /
# external-dns 1.21.1 / cilium 1.19.4). ---
VERSIONS = {
    "external-secrets": "2.6.0",
    "traefik": "40.2.0",
    "external-dns": "1.21.1",
    "cert-manager": "v1.20.2",
    "k8s-monitoring": "4.1.4",
    "prometheus-node-exporter": "4.55.0",
    "cilium": "1.19.4",
    "metrics-server": "3.13.1",  # app v0.8.1 — Talos-only (k3s bundles its own)
    "nats": "2.14.0",  # already pinned in the legacy task
    "tailscale-operator": "1.98.3",  # already pinned in the legacy task
    "argo-cd": "9.5.17",  # Argo CD v3.4.3 — the GitOps controller (minipc)
    # CNPG — operator v1.30.0 + the barman-cloud CNPG-I plugin v0.13.0 (WAL
    # archiving / PITR to S3). Verified latest stable at add time (2026-07-10).
    "cloudnative-pg": "0.29.0",
    "plugin-barman-cloud": "0.7.0",
    # ARC — controller + runner scale set share one release version.
    "arc-controller": "0.14.2",
    "arc-runner-set": "0.14.2",
}


@dataclass(frozen=True)
class HelmComponent:
    """One Helm release: chart coords + the legacy value files to feed it."""

    release: str  # helm release name (matches the live release)
    repo_key: str  # key into REPOS
    chart: str  # bare chart name (repo is passed separately)
    version_key: str  # key into VERSIONS
    namespace: str
    value_files: tuple[str, ...] = ()  # -f paths under K8S
    values: dict = field(default_factory=dict)  # extra inline overrides (e.g. LAN IP)
    # Argo-manageable? False for the bootstrap floor Argo can't own — cilium (the
    # CNI Argo itself rides on) and argo-cd (managing its own install). Those stay
    # task-installed; the Argo-native platform layer (argo_platform.py) skips them.
    argo: bool = True

    def emit(self, scope: Construct) -> Helm:
        flags = ["--namespace", self.namespace]
        for vf in self.value_files:
            flags += ["-f", f"{K8S}/{vf}"]
        return Helm(
            scope,
            self.release,
            chart=self.chart,
            repo=REPOS[self.repo_key],
            version=VERSIONS[self.version_key],
            release_name=self.release,
            namespace=self.namespace,
            helm_flags=flags,
            values=self.values or {},
        )


def cluster_components(
    cluster: str, env: EnvConfig, skip_monitoring: bool = False
) -> list[HelmComponent]:
    """The cluster-scoped platform Helm releases for one cluster, in install
    order. Shared source of truth for both delivery paths: PlatformChart renders
    them via cdk8s.Helm; argo_platform emits an Argo Application per
    Argo-manageable one. Excludes the per-env charts (external-dns, NATS — see
    `env_components`) and the kustomize-only bits (local-path-provisioner,
    intel-gpu/xpu, ESO cluster-store, cert-manager app-issuers)."""
    minipc = cluster == "minipc"
    components: list[HelmComponent] = []
    if minipc:
        # Cilium first — CNI + kube-proxy replacement; nothing schedules until
        # it's up (Talos installs neither). Bootstrap floor: Argo can't own the
        # CNI it rides on, so argo=False.
        components.append(
            HelmComponent(
                "cilium",
                "cilium",
                "cilium",
                "cilium",
                "kube-system",
                value_files=("cilium/values.yml",),
                argo=False,
            )
        )
        # metrics-server — backs `kubectl top` + the HPA metrics API. Talos
        # doesn't bundle it (k3s does, so the k3d dev cluster already has it);
        # minipc-only. --kubelet-insecure-tls in values.yml works around Talos's
        # self-signed kubelet serving certs. Cleanly Argo-manageable (no
        # host-coupled values), unlike the bootstrap-floor charts above.
        components.append(
            HelmComponent(
                "metrics-server",
                "metrics-server",
                "metrics-server",
                "metrics-server",
                "kube-system",
                value_files=("metrics-server/values.yml",),
            )
        )

    components.append(
        HelmComponent(
            "external-secrets",
            "external-secrets",
            "external-secrets",
            "external-secrets",
            "external-secrets",
            value_files=("external-secrets/values.yml",),
        )
    )

    if minipc:
        components.append(
            HelmComponent(
                "tailscale-operator",
                "tailscale",
                "tailscale-operator",
                "tailscale-operator",
                "tailscale",
                value_files=("tailscale-operator/values.yml",),
            )
        )

    # Argo CD — the GitOps controller itself, on every cluster that runs an Argo
    # (minipc + the k3d dev cluster; local doesn't). k3d layers values.k3d.yml over
    # the base to swap the tailnet domain / managed-namespace for development.
    # Bootstrap floor (Argo managing its own install is a footgun), so argo=False;
    # stays task-installed.
    if cluster in ("minipc", "k3d"):
        argo_values = ["argo-cd/values.yml"]
        if cluster == "k3d":
            argo_values.append("argo-cd/values.k3d.yml")
        components.append(
            HelmComponent(
                "argocd",
                "argo",
                "argo-cd",
                "argo-cd",
                "argocd",
                value_files=tuple(argo_values),
                argo=False,
            )
        )

    # traefik on the mini-PC runs hostNetwork and stamps the LAN IP into
    # Ingress status (replaces values.local.yml's ingressEndpoint.ip).
    #
    # NOT Argo-manageable (argo=False): ingressEndpoint.ip is the node's
    # InternalIP, discovered at bootstrap and written to the gitignored
    # values.local.yml — it's host state, not git-declarable (prod's differs from
    # the committed lan_ip). Inlining env.lan_ip would make Argo stamp the wrong
    # IP into every Ingress on adoption, so traefik stays task-installed (the
    # bootstrap discovers the IP). Same class as cilium/argo-cd.
    traefik_files = ["traefik/values.yml"]
    traefik_values: dict = {}
    if minipc:
        traefik_files.append("traefik/values.prod-1.yml")
        traefik_values = {
            "providers": {"kubernetesIngress": {"ingressEndpoint": {"ip": env.lan_ip}}}
        }
    components.append(
        HelmComponent(
            "traefik",
            "traefik",
            "traefik",
            "traefik",
            "kube-system",
            value_files=tuple(traefik_files),
            values=traefik_values,
            argo=False,
        )
    )

    components.append(
        HelmComponent(
            "cert-manager",
            "jetstack",
            "cert-manager",
            "cert-manager",
            "kube-system",
            value_files=(f"cert-manager/{env.name}/config.yml",),
        )
    )

    # CloudNativePG — Postgres operator, backing the stage-1/prod-1 `pg`
    # clusters (PITR via WAL archiving to S3). The barman-cloud CNPG-I plugin
    # handles the S3 side; it needs cert-manager (webhook certs), so both sit
    # after it in install order.
    components.append(
        HelmComponent(
            "cnpg",
            "cloudnative-pg",
            "cloudnative-pg",
            "cloudnative-pg",
            "cnpg-system",
            value_files=("cloudnative-pg/values.yml",),
        )
    )
    components.append(
        HelmComponent(
            "plugin-barman-cloud",
            "cloudnative-pg",
            "plugin-barman-cloud",
            "plugin-barman-cloud",
            "cnpg-system",
            value_files=("plugin-barman-cloud/values.yml",),
        )
    )

    components.append(
        HelmComponent(
            "node-exporter",
            "prometheus-community",
            "prometheus-node-exporter",
            "prometheus-node-exporter",
            "monitoring-host",
            value_files=("monitoring/node-exporter/values.yml",),
        )
    )

    # k8s-monitoring 4.1.4 is confirmed live on the minipc (prod renders + the
    # pin matches `helm list`). But dev's values.yml was authored for the k3d dev
    # cluster's OLDER deployed chart and trips the chart's collector-validation
    # under 4.1.3. Until that cluster's live version is captured (it's on a
    # separate box) and pinned, dev monitoring is skipped here rather than guessed
    # — it stays on the legacy `task k8s:dev:platform:up` helm install. prod/stage
    # are unaffected.
    if not skip_monitoring:
        components.append(
            HelmComponent(
                "k8s-monitoring",
                "grafana",
                "k8s-monitoring",
                "k8s-monitoring",
                "monitoring",
                value_files=(f"monitoring/{env.name}/values.yml",),
            )
        )

    return components


def env_components(env: EnvConfig) -> list[HelmComponent]:
    """The per-env-platform Helm releases (external-dns + NATS) for one env,
    landing in its `<env>-platform` namespace. Shared by PlatformEnvChart (cdk8s.Helm)
    and argo_platform (one Argo Application each)."""
    platform_ns = f"{env.name}-platform"
    # dev keeps external-dns in kube-system (legacy); minipc envs use the
    # env-platform namespace so the app namespace stays pod-clean.
    edns_ns = platform_ns if env.cluster == "minipc" else "kube-system"
    # Stage's external-dns release is named external-dns-stage (cluster-scoped
    # RBAC can't collide with prod's external-dns on the shared cluster).
    edns_release = "external-dns-stage" if env.name == "stage-1" else "external-dns"
    return [
        HelmComponent(
            edns_release,
            "external-dns",
            "external-dns",
            "external-dns",
            edns_ns,
            value_files=(f"external-dns/{env.name}/config.yml",),
            # `extraArgs` (--default-targets=<node IP> + --force-default-targets)
            # lives in the gitignored values.local.yml, written by bootstrap from
            # the node's discovered InternalIP. The cdk8s.Helm path approximates it
            # with the committed lan_ip, but it's NOT git-declarable — NOT
            # Argo-manageable (argo=False). Like traefik (its IP source) and
            # cilium/argo-cd, external-dns stays task-installed so the bootstrap
            # owns the discovered IP + the force flag. Inlining lan_ip here would
            # make Argo drop --force-default-targets and force the wrong target on
            # adoption.
            values={"extraArgs": [f"--default-targets={env.lan_ip}"]},
            argo=False,
        ),
        HelmComponent(
            "nats",
            "nats",
            "nats",
            "nats",
            platform_ns,
            value_files=("nats/values.yml", f"nats/{env.name}/values.yml"),
        ),
    ]


def arc_components() -> list[HelmComponent]:
    """The Actions Runner Controller releases — controller (arc-systems) + one
    arm64 runner scale set registered to the tripbot repo (arc-runners). minipc
    only; the runner pods land on the rpi5 (placement is in the values files).

    OCI charts: Argo renders them in-cluster, so these are emitted ONLY by
    argo_platform (Applications), never by PlatformChart (cdk8s.Helm can't
    `helm template` an OCI ref). The supporting namespaces / quota / GitHub App
    ExternalSecret are a separate deploy unit (constructs/arc.py)."""
    return [
        HelmComponent(
            "arc-controller",
            "actions-runner",
            "gha-runner-scale-set-controller",
            "arc-controller",
            "arc-systems",
            value_files=("arc/controller/values.yml",),
        ),
        HelmComponent(
            "arc-arm64-tripbot",
            "actions-runner",
            "gha-runner-scale-set",
            "arc-runner-set",
            "arc-runners",
            value_files=("arc/runners/values.yml",),
        ),
    ]


class PlatformChart(Chart):
    """Cluster-scoped platform stack for one cluster (`minipc` | `k3d`),
    rendered via cdk8s.Helm (opt-in CDK8S_PLATFORM synth). The component table
    lives in `cluster_components`; this just renders it. The Argo-native delivery
    path (argo_platform.py) reads the SAME table. Excludes the per-env charts
    (external-dns, NATS → PlatformEnvChart) and the kustomize-only components."""

    def __init__(
        self,
        scope: Construct,
        id: str,
        *,
        cluster: str,
        env: EnvConfig,
        skip_monitoring: bool = False,
    ):
        super().__init__(scope, id)
        for comp in cluster_components(cluster, env, skip_monitoring):
            comp.emit(self)


class PlatformEnvChart(Chart):
    """Per-env-platform charts in the `<env>-platform` namespace: external-dns
    (publishes the env's Route53 zone to the LAN IP) and NATS (the pubsub bus),
    rendered via cdk8s.Helm. Component table in `env_components`. Separate from
    PlatformChart so stage + prod can co-tenant one cluster with isolated platform
    namespaces."""

    def __init__(self, scope: Construct, id: str, *, env: EnvConfig):
        super().__init__(scope, id)
        for comp in env_components(env):
            comp.emit(self)
