"""Platform Helm layer: the in-cluster platform stack wrapped in
`cdk8s.Helm`, which renders each chart via `helm template` at synth time.

Replaces the imperative `helm upgrade --install` sequence in `k8s:<env>:platform:up`
with declarative, **version-pinned** charts. Reuses the existing
`k8s/<component>/values*.yml` files verbatim (passed through with `-f`), so this
is a tooling change, not a values rewrite.

Two deploy units (mirrors the legacy split):
  * `PlatformChart(cluster)`  — the cluster-scoped platform (cilium, ESO, traefik,
    cert-manager, node-exporter, victoria-metrics, k8s-monitoring,
    tailscale-operator).
  * `PlatformEnvChart(env)`   — the per-env-platform pieces that live in the
    `<env>-platform` namespace (external-dns, NATS), with the LAN IP injected
    from `EnvConfig` (replacing the gitignored `values.local.yml`).

Version pins live in `platform-charts/Chart.yaml`, where Dependabot bumps them.
Confirm against a live `helm list -A` before a cutover that they match what's
deployed.

The kustomize-only platform bits (local-path-provisioner, intel-gpu-plugin,
intel-xpu-manager, the ESO cluster-store, cert-manager ClusterIssuers) are NOT
Helm charts — they stay kustomize-applied as today; see the notes in
`PlatformChart`. Ordering (Cilium first, local-path before PVCs, ESO before
ExternalSecrets, cert-manager CRDs before Issuers) is enforced by applying the
platform chart before apps, exactly as the legacy task ordering did.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import yaml
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
    "victoria-metrics": "https://victoriametrics.github.io/helm-charts/",
    # OCI registry — no scheme, the form Argo's repoURL wants. emit() detects
    # the missing scheme and passes helm the full oci:// chart ref instead.
    "burrito": "ghcr.io/padok-team/charts",
    "actions-runner": "ghcr.io/actions/actions-runner-controller-charts",
    "kyverno": "https://kyverno.github.io/kyverno",
}

# --- Version pins: platform-charts/Chart.yaml, keyed by chart name. They live
# there rather than in a dict here because that is the format Dependabot's
# `helm` ecosystem reads, so a newer chart arrives as a PR. ---
PINS = yaml.safe_load(
    (Path(__file__).parent.parent / "platform-charts/Chart.yaml").read_text()
)["dependencies"]
VERSIONS = {d["name"]: str(d["version"]) for d in PINS}


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
    # In-repo raw manifest (path under K8S) delivered alongside the chart — the
    # custom resources of a CRD the chart ships, so they sync with the operator
    # that reconciles them. Argo path only; the cdk8s.Helm render skips it.
    manifests: str = ""
    # Argo-manageable? False for the bootstrap floor Argo can't own — cilium (the
    # CNI Argo itself rides on) and argo-cd (managing its own install). Those stay
    # task-installed; the Argo-native platform layer (argo_platform.py) skips them.
    argo: bool = True

    def emit(self, scope: Construct) -> Helm:
        flags = ["--namespace", self.namespace]
        for vf in self.value_files:
            flags += ["-f", f"{K8S}/{vf}"]
        repo = REPOS[self.repo_key]
        if "://" not in repo:
            # OCI registry (scheme-less in REPOS, matching Argo's repoURL
            # format). helm can't take an OCI registry via --repo — it wants
            # the full oci:// chart ref as the chart argument.
            chart, repo = f"oci://{repo}/{self.chart}", None
        else:
            chart = self.chart
        return Helm(
            scope,
            self.release,
            chart=chart,
            repo=repo,
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
    intel-gpu/xpu, ESO cluster-store). The per-namespace cert-manager Issuers
    come from `supporting.emit_supporting`."""
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
                manifests="tailscale-operator/proxygroup.yml",
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

    # Burrito — terraform GitOps controller ("Argo CD for terraform"), a
    # plan/drift-detect TRIAL: no layer enables remediationStrategy.autoApply
    # and the runner credential is read-only, so applies stay Dana-driven per
    # the write-side preference. Mock (in-memory) datastore — plan artifacts
    # don't survive a datastore restart; a real S3 bucket is the promotion
    # step if the trial sticks. Cleanly Argo-manageable (no host-coupled
    # values). The CRs it reconciles (TerraformRepository/TerraformLayer) live
    # in dist/burrito.k8s.yaml — see constructs/burrito.py.
    if minipc:
        components.append(
            HelmComponent(
                "burrito",
                "burrito",
                "burrito",
                "burrito",
                "burrito-system",
                value_files=("burrito/values.yml",),
            )
        )

    # Argo Workflows — the batch/DAG engine for the spare-compute passes that are
    # hand-applied one-shot Jobs today (video-pipeline's embed/coords/auto-trim).
    # Runs three workflows at a time at the most-preemptible priority, so a queue of
    # them yields to the stream. Cleanly Argo-manageable (no host-coupled values).
    # The CRs it runs are Workflows, submitted by hand or by the video-pipeline
    # repo — nothing in this repo declares one. The raw manifest is the
    # console's read-only grant on them in stage-1.
    if minipc:
        components.append(
            HelmComponent(
                "argo-workflows",
                "argo",
                "argo-workflows",
                "argo-workflows",
                "argo-workflows",
                value_files=("argo-workflows/values.yml",),
                manifests="argo-workflows/console-rbac.yml",
            )
        )

    # ARC (Actions Runner Controller) — self-hosted GitHub Actions runners for
    # the private repos (free-plan minutes are metered there). Two OCI charts:
    # the reconciler in arc-systems, plus one amd64 runner scale set registered
    # at the ORG level so a single pool serves every private repo
    # (runs-on: arc-amd64). The supporting namespaces / LimitRange /
    # GitHub App ExternalSecret are the ArcChart singleton (constructs/arc.py).
    if minipc:
        components.append(
            HelmComponent(
                "arc-controller",
                "actions-runner",
                "gha-runner-scale-set-controller",
                "gha-runner-scale-set-controller",
                "arc-systems",
                value_files=("arc/controller/values.yml",),
            )
        )
        components.append(
            HelmComponent(
                "arc-amd64",
                "actions-runner",
                "gha-runner-scale-set",
                "gha-runner-scale-set",
                "arc-runners",
                value_files=("arc/runners/values.yml",),
            )
        )

    # Kyverno — admission policy engine, validation-only and fail-open (see
    # k8s/kyverno/values.yml). Cleanly Argo-manageable (no host-coupled values).
    if minipc:
        components.append(
            HelmComponent(
                "kyverno",
                "kyverno",
                "kyverno",
                "kyverno",
                "kyverno",
                value_files=("kyverno/values.yml",),
                manifests="kyverno/policies.yml",
            )
        )

    # traefik on the mini-PC runs hostNetwork and stamps the LAN IP into
    # Ingress status (replaces values.local.yml's ingressEndpoint.ip).
    #
    # NOT Argo-manageable (argo=False), and what installs on the minipc is
    # k8s/traefik/values.prod-1.yml — which stamps ingressEndpoint.hostname with
    # the location-independent alias, not an address. env.lan_ip below is the
    # render's stale approximation of that and reaches no cluster. development is
    # the env that genuinely can't be git-declared: its target is the host's own
    # public IP, per-machine. Same class as cilium/argo-cd.
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

    # VictoriaMetrics — the local, full-fidelity metrics store that
    # k8s-monitoring's localMetrics destination writes to (the Grafana Cloud
    # destination gets the series-cap-trimmed subset). minipc only: dev ships
    # logs + events, no local TSDB. Before k8s-monitoring so a fresh cluster
    # has the destination up before alloy's first write (alloy retries, so
    # this is politeness, not a hard dependency).
    if minipc:
        components.append(
            HelmComponent(
                "victoria-metrics",
                "victoria-metrics",
                "victoria-metrics-single",
                "victoria-metrics-single",
                "monitoring",
                value_files=("monitoring/victoria-metrics/values.yml",),
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
            # prod-1 and stage-1 commit their own `extraArgs`
            # (--default-targets=<node alias> + --force-default-targets) in
            # k8s/external-dns/<env>/config.yml, and that is what
            # `task k8s:<env>:platform:up` installs. The value rendered here from
            # env.lan_ip approximates it and reaches no cluster. external-dns
            # stays task-installed (argo=False) alongside traefik and
            # cilium/argo-cd because development's target is the host's own
            # public IP, written per-machine to a gitignored values.local.yml.
            values={"extraArgs": [f"--default-targets={env.lan_ip}"]},
            argo=False,
        ),
        # The release name is what the chart names the Service, so it is the
        # `services.nats` every consumer dials (tripbot, playout and the console
        # each build nats://<name>.<env>-platform.svc.cluster.local from the
        # contract). Deliberately a literal rather than a contract read: renaming
        # a Helm release is an uninstall/install, so this name must move on its
        # own schedule and not because a JSON key changed under it.
        HelmComponent(
            "nats",
            "nats",
            "nats",
            "nats",
            platform_ns,
            value_files=("nats/values.yml", f"nats/{env.name}/values.yml"),
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
