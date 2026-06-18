#!/usr/bin/env python
"""cdk8s entrypoint. Synthesizes the deploy units into dist/.

Per env:  <env>-supporting              — shared obs Secrets, cert-manager Issuers
          <env>-data                    — postgres + dashcam PVC (stateful, never pruned)

The tripbot app workloads (<env>-<component>-<platform>), one-shot Jobs, and
identity Secrets (<env>-tripbot-identity) are authored in the tripbot repo's
cdk8s now, and the dashcam-cv vector-fill workload in the video-pipeline repo's;
Argo delivers both cross-repo (see constructs/argocd.py).

Synth all envs by default; CDK8S_ENV=<name> narrows to one (handy for diffing a
single env's output).
"""

import os

from cdk8s import App

from adanalife_k8s.charts import (
    ArgoCDChart,
    DashcamPVChart,
    DataChart,
    PlatformArgoChart,
    SupportingChart,
    UpsMonitorChart,
)
from adanalife_k8s.config import ENVS, load_env
from adanalife_k8s.helm_platform import PlatformChart, PlatformEnvChart

# outdir honors CDK8S_OUTDIR so a caller can synth to a throwaway dir without
# touching the committed dist/ — used by `task k8s:<env>:dashcam-pv`, which synths
# the PV with real (gitignored) NFS coords and applies it out of band.
app = App(outdir=os.environ.get("CDK8S_OUTDIR", "dist"))

only = os.environ.get("CDK8S_ENV")
targets = [only] if only else list(ENVS)
for name in targets:
    env = load_env(name)
    # Per-env namespace supporting resources (shared observability Secrets +
    # cert-manager issuers), isolated from the app churn — its own deploy unit /
    # Argo Application. The tripbot APP workloads, one-shot Jobs, and identity
    # Secrets are authored in the tripbot repo now (Argo delivers them cross-repo).
    SupportingChart(app, f"{name}-supporting", env=env)
    # Stateful resources (postgres + dashcam PV/PVC) as a separate deploy unit /
    # Argo Application — isolated from the app churn, synced before the apps.
    DataChart(app, f"{name}-data", env=env)
    # dashcam NFS PV (nfs envs only) — cluster-scoped host-specific bootstrap
    # infra, its own deploy unit OUTSIDE Argo (the apps/data ApplicationSets
    # don't glob it). Applied via `task k8s:<env>:dashcam-pv`. Committed dist
    # carries NFS placeholders; the task injects real coords at synth time.
    if env.dashcam_mode == "nfs":
        DashcamPVChart(app, f"{name}-dashcam-pv", env=env)
    # The dashcam-cv vector-fill workload moved to the video-pipeline repo (it owns
    # its own cdk8s/dist now); Argo delivers it cross-repo via the video-pipeline
    # ApplicationSet (see constructs/argocd.py).

# Argo CD GitOps config (env-agnostic, offline) — committed deploy unit applied
# after the Argo install. Skipped when narrowed to a single env via CDK8S_ENV.
if not only:
    # minipc Argo — prod-1 + stage-1, tailscale UI.
    ArgoCDChart(app, "argocd")
    # k3d (development) Argo — a SEPARATE in-cluster install managing only
    # development (dev apps autosync since the env is throwaway). Each Argo targets
    # its own cluster in-cluster, so there's no cross-cluster wiring. No tailnet UI
    # (no tailscale-operator on the dev cluster); the UI rides a traefik Ingress at
    # argocd.dev.whereisdana.today (no TLS), reached at :9080 via the k3d port-map.
    # selfHeal off: dev autosync still deploys git changes, but a hand `kubectl
    # edit` sticks (Argo shows OutOfSync rather than stomping it) — dev is a
    # scratch env for manual experimentation.
    ArgoCDChart(
        app,
        "argocd-k3d",
        envs=("development",),
        autosync_envs=("development",),
        autosync_holdouts=(),  # the prod OBS holdout is minipc-only
        selfheal=False,
        notifications_secret=False,  # dev runs notifications.enabled=false
        tailscale_ui=False,
        lan_host=f"argocd.{load_env('development').dns_base}",
        lan_tls=False,
        ups_monitor=False,  # the k3d dev cluster can't reach the Synology NUT server
    )
    # Argo-native delivery of the platform Helm stack — one multi-source Helm
    # Application per release (offline: just Application objects, no rendered
    # charts). MONITOR-ONLY until adopted; see gitops/README.md.
    PlatformArgoChart(app, "platform-argo")
    # UPS monitor (observe-only NUT client) — cluster-singleton in the `ups`
    # namespace, env-agnostic. Delivered by a minipc-only Argo Application (the
    # k3d dev Argo doesn't reference it — that cluster can't reach the Synology
    # NUT server). See constructs/ups_monitor.py.
    UpsMonitorChart(app, "ups-monitor")

# Platform Helm stack is opt-in: it renders charts via `helm template` (needs
# helm + network), so the default apps synth stays fast and offline. Enable with
# CDK8S_PLATFORM=1. The cluster-scoped chart is per CLUSTER (stage rides prod's);
# the env-platform chart (external-dns + NATS) is per env-platform namespace.
if os.environ.get("CDK8S_PLATFORM"):
    PlatformChart(app, "platform-minipc", cluster="minipc", env=load_env("prod-1"))
    # the k3d dev cluster's k8s-monitoring needs its live chart version pinned
    # first (see PlatformChart) — skip it here so the synth stays green until captured.
    PlatformChart(
        app,
        "platform-k3d",
        cluster="k3d",
        env=load_env("development"),
        skip_monitoring=True,
    )
    for name in ("prod-1", "stage-1", "development"):
        PlatformEnvChart(app, f"{name}-platform", env=load_env(name))

app.synth()
