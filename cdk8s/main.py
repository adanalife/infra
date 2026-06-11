#!/usr/bin/env python
"""cdk8s entrypoint. Synthesizes the deploy units into dist/.

Per env:  <env>-<component>-<platform>  — one deploy unit / Argo Application each
          <env>-supporting              — shared + identity Secrets, cert-manager Issuers
          <env>-data                    — postgres + dashcam PVC (stateful, never pruned)
          <env>-job-<name>              — tripbot one-shot Jobs (auth/seed; their own tasks)
stage:    dashcam-cv[-jobs]             — the vector-fill batch workload (its own task)

Synth all envs by default; CDK8S_ENV=<name> narrows to one (handy for diffing a
single env's output).
"""

import os

from cdk8s import App

from adanalife_k8s.charts import (
    ArgoCDChart,
    DashcamCVChart,
    DashcamCVJobsChart,
    DashcamPVChart,
    DataChart,
    emit_job_charts,
    PlatformArgoChart,
    SupportingChart,
    emit_app_charts,
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
    # One Chart per (component, platform) -> dist/<env>-<component>-<platform>.k8s.yaml.
    emit_app_charts(app, env)
    # Per-env namespace supporting resources (shared/identity Secrets + issuers),
    # isolated from the app churn — its own deploy unit / Argo Application.
    SupportingChart(app, f"{name}-supporting", env=env)
    # Stateful resources (postgres + dashcam PV/PVC) as a separate deploy unit /
    # Argo Application — isolated from the app churn, synced before the apps.
    DataChart(app, f"{name}-data", env=env)
    emit_job_charts(app, env)
    # dashcam NFS PV (nfs envs only) — cluster-scoped host-specific bootstrap
    # infra, its own deploy unit OUTSIDE Argo (the apps/data ApplicationSets
    # don't glob it). Applied via `task k8s:<env>:dashcam-pv`. Committed dist
    # carries NFS placeholders; the task injects real coords at synth time.
    if env.dashcam_mode == "nfs":
        DashcamPVChart(app, f"{name}-dashcam-pv", env=env)
    # dashcam-cv is stage-only today (the only env running the vector fill).
    # The persistent fill workload and the on-demand one-shot Jobs are separate
    # deploy units so a normal apply never re-runs the Jobs.
    if name == "stage-1":
        DashcamCVChart(app, "dashcam-cv", env=env)
        DashcamCVJobsChart(app, "dashcam-cv-jobs", env=env)

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
    ArgoCDChart(
        app,
        "argocd-k3d",
        envs=("development",),
        autosync_envs=("development",),
        tailscale_ui=False,
        lan_host=f"argocd.{load_env('development').dns_base}",
        lan_tls=False,
    )
    # Argo-native delivery of the platform Helm stack — one multi-source Helm
    # Application per release (offline: just Application objects, no rendered
    # charts). MONITOR-ONLY until adopted; see gitops/README.md.
    PlatformArgoChart(app, "platform-argo")

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
