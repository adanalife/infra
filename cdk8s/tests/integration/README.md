# Integration tests (post-apply, live cluster)

These pytest tests run **against a live Kubernetes cluster** after the synthesized
manifests have been applied. They are the verification harness for the
Kustomize → cdk8s migration cutover: they assert the workloads actually came up,
Services have endpoints, and Ingresses got addresses.

This is distinct from `tests/unit/`, which is **synth-time** (no cluster — it
inspects the cdk8s output dict). Integration tests inspect *real* cluster state via
the official [`kubernetes`](https://github.com/kubernetes-client/python) Python
client.

## Safe to run anywhere

The suite **skips cleanly** when:

- no cluster is reachable (no kubeconfig, apiserver down, wrong context), or
- the target namespace doesn't exist on the reachable cluster (env not applied here).

So `uv run pytest tests/integration -q` in CI with no cluster just reports skips —
it never hard-errors on collection.

## Running against a real env

```sh
# 1. apply the env (example: stage)
task k8s:stage:apply

# 2. point kubeconfig at that cluster (e.g. the tailscale-operator context),
#    then run the suite against its namespace:
mise exec -- uv run pytest tests/integration --env stage-1 -q
```

`--env` selects which `EnvConfig` (and therefore which namespace + expected
workload set) to assert against. Valid values: `prod-1`, `stage-1`, `development`,
`local`. Default is `stage-1`.

## What it asserts

- **Deployments Available** — `tripbot`, `vlc-server`, `onscreens-server`,
  `obs-twitch` (plus `obs-youtube` on stage, derived from `env.platforms`).
  Available via the `Available` condition or `availableReplicas >= 1`.
- **Postgres StatefulSet** has `readyReplicas >= 1`.
- **Services with Endpoints** — `vlc-server`, `onscreens-server`, `obs-twitch`,
  `postgres`, `tripbot` each exist and have at least one ready backing address.
- **Ingress LB addresses** — on minipc envs (`stage-1`, `prod-1`), `vlc-server`
  and `tripbot` Ingresses should have a load-balancer IP/hostname. A *missing*
  Ingress is a hard fail; an Ingress present but *without an address yet* is an
  `xfail` (external-dns / traefik can lag — not a defect).
- **OBS websocket port** — the `obs-twitch` Service exposes the `websocket` port
  (`4455`, from `contract.json`). We assert the port exists rather than dialing
  it, because an in-cluster TCP connect needs the test host on the cluster /
  tailnet network, which CI and dev laptops don't have. See the comment in
  `test_obs_websocket_port_exposed`.

The expected-workload set is **derived** from `adanalife_k8s.config.load_env` and
`adanalife_k8s.contract.load_contract` (the same sources the charts synth from),
not hardcoded — so it can't drift from what was deployed.
