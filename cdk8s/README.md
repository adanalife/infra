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
uv run cdk8s synth                 # -> dist/<env>-{apps,jobs}.k8s.yaml (all envs, fast, offline)
CDK8S_ENV=stage-1 uv run cdk8s synth   # one env (handy for diffing vs legacy)
uv run pytest -q                   # unit + parity + contract tests
uv run python tests/parity.py      # diff synth vs the legacy kustomize render
```

The **app** synth is offline and fast. The **platform Helm** synth renders charts
via `helm template`, so it needs helm + network and is opt-in:

```bash
# capture the kustomize reference once (the parity oracle):
for e in local development stage-1 prod-1; do kubectl kustomize ../k8s/overlays/$e > reference/$e.kustomize.yaml; done
# platform stack (cilium / ESO / traefik / cert-manager / monitoring / nats / external-dns / tailscale):
CDK8S_PLATFORM=1 uv run cdk8s synth   # -> dist/platform-*.k8s.yaml + dist/<env>-platform.k8s.yaml
```

NFS coordinates for the dashcam PV are threaded in at synth from `$NFS_SERVER` /
`$NFS_PATH` (never committed; placeholders match the legacy `.example`).

## Layout

- `adanalife_k8s/config.py` — `EnvConfig` + the per-env matrix (`ENVS`).
- `adanalife_k8s/charts.py` — `AppsChart` (umbrella app set per env), `JobsChart`
  (one-shot auth/seed Jobs), `DashcamCVChart` (stage-only vector fill).
- `adanalife_k8s/constructs/` — the app factories: `ObsInstance` (per-platform),
  `VlcServer`, `OnscreensServer`, `Tripbot` (+ `emit_jobs`), `Postgres`, `DashcamCV`.
- `adanalife_k8s/{naming,configmap,appconfig,eso,supporting}.py` — shared helpers
  (labels, stable-name ConfigMaps + content-hash, config blocks, ESO CR builders,
  per-ns SecretStore + shared-secrets + cert-manager issuers).
- `adanalife_k8s/helm_platform.py` — `PlatformChart` (per cluster) + `PlatformEnvChart`
  (per env-platform ns); version-pinned `cdk8s.Helm` wrappers reusing `k8s/*/values*.yml`.
- `contract.json` — synced from tripbot (service names / ports / env keys); the
  anti-drift bridge. tripbot owns it via `go generate` (`pkg/contract`); `task contract:sync`.
- `tests/unit` — synth-time (per-construct + render-parity gate); `tests/parity.py`
  — diffs synth vs the legacy kustomize render, normalizing the intended divergences
  (stable ConfigMap/Secret names, the `config-hash` annotation, the obs→obs-twitch rename).
- `reference/` — captured kustomize renders (the parity oracle; gitignored).
