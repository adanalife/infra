#!/usr/bin/env python
"""cdk8s entrypoint. Synthesizes the deploy units into dist/.

Per env:  <env>-apps   — the umbrella app set (applied on every `task k8s:<env>:apply`)
          <env>-jobs    — tripbot one-shot Jobs (applied via the auth/seed tasks)
stage:    dashcam-cv    — the vector-fill batch workload (its own task)

Synth all envs by default; CDK8S_ENV=<name> narrows to one (handy for diffing a
single env's output against the legacy Kustomize render during migration).
"""

import os

from cdk8s import App

from adanalife_k8s.charts import (
    ArgoCDChart,
    DashcamCVChart,
    DashcamCVJobsChart,
    DashcamPVChart,
    DataChart,
    JobsChart,
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
    JobsChart(app, f"{name}-jobs", env=env)
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
    ArgoCDChart(app, "argocd")

# Platform Helm stack is opt-in: it renders charts via `helm template` (needs
# helm + network), so the default apps synth stays fast and offline. Enable with
# CDK8S_PLATFORM=1. The cluster-scoped chart is per CLUSTER (stage rides prod's);
# the env-platform chart (external-dns + NATS) is per env-platform namespace.
if os.environ.get("CDK8S_PLATFORM"):
    PlatformChart(app, "platform-minipc", cluster="minipc", env=load_env("prod-1"))
    # bees k8s-monitoring needs its live chart version pinned first (see
    # PlatformChart) — skip it here so the synth stays green until captured.
    PlatformChart(
        app,
        "platform-bees",
        cluster="bees",
        env=load_env("development"),
        skip_monitoring=True,
    )
    for name in ("prod-1", "stage-1", "development"):
        PlatformEnvChart(app, f"{name}-platform", env=load_env(name))

app.synth()
