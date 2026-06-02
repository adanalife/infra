# cdk8s — Kubernetes authoring layer (Python)

Programmatic, typed, testable replacement for the Kustomize `k8s/` overlays.
Synthesizes plain YAML (Flux/Argo-ready) that's applied with `kubectl`. Terraform
stays authoritative for cloud; this manages **only** Kubernetes. See the migration
plan and `vault/decisions/` for rationale.

## Setup

Tools are pinned via mise (`.mise.toml`): python, node, cdk8s-cli, helm. Python
deps via uv.

```bash
mise install            # python, node, cdk8s-cli, helm
uv sync                 # python deps into .venv
cdk8s import            # generate typed k8s constructs into imports/ (gitignored)
```

## Develop

```bash
uv run cdk8s synth                 # -> dist/<env>-apps.k8s.yaml (all envs)
CDK8S_ENV=stage-1 uv run cdk8s synth   # one env (handy for diffing vs legacy)
uv run pytest -q                   # unit / snapshot / contract tests
```

## Layout

- `adanalife_k8s/config.py` — `EnvConfig` + the per-env matrix (`ENVS`).
- `adanalife_k8s/charts.py` — `AppsChart` (per env); `PlatformChart` (later).
- `adanalife_k8s/constructs/` — the per-platform factories (`ObsInstance`, …).
- `contract.json` — synced from tripbot (service names / ports / env keys); the
  anti-drift bridge. `task contract:sync`.
- `tests/unit` — synth-time; `tests/integration` — post-apply (k8s client).
