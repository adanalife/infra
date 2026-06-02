#!/usr/bin/env python
"""cdk8s entrypoint. Synthesizes one Chart per environment into dist/.

Synth all envs by default; CDK8S_ENV=<name> narrows to one (handy for diffing a
single env's output against the legacy Kustomize render during migration).
"""
import os

from cdk8s import App

from adanalife_k8s.charts import AppsChart
from adanalife_k8s.config import ENVS, load_env

app = App()

only = os.environ.get("CDK8S_ENV")
targets = [only] if only else list(ENVS)
for name in targets:
    env = load_env(name)
    AppsChart(app, f"{name}-apps", env=env)

app.synth()
