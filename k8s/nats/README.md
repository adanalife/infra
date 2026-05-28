# k8s/nats

NATS message bus — **phase 0**: deploy chart per-env, no JetStream, no PVC,
single-node. Tracked by the NATS bullet in `vault/tripbot/TODO.md`
(captured 2026-05-28).

## Why NATS

Decouple producer/consumer for inter-component traffic. Today
chatbot ↔ vlc-server ↔ onscreens-server is point-to-point HTTP
(`pkg/onscreens-client`, `pkg/vlc-client`). Phase 1 will migrate one
fire-and-forget call (`onscreens-client.ShowMiddleText`) as proof; later
phases peel off the rest of the onscreens-client surface, then
`video.changed`, then session/stream lifecycle events. Queries stay on HTTP.

## Layout

```
k8s/nats/
├── values.yml              # shared chart values (JetStream off, prom-exporter on)
├── development/values.yml  # per-env resource sizing
├── stage-1/values.yml
└── prod-1/values.yml
```

No kustomizations — `helm upgrade --install ... --create-namespace` from the
per-env `platform:up` (dev/prod) or `apply` (stage) Taskfile target does
everything.

## Where it lives in the cluster

| Env         | Namespace             | Installed by                |
|-------------|-----------------------|-----------------------------|
| development | `development-platform`| `task k8s:dev:platform:up`  |
| stage-1     | `stage-1-platform`    | `task k8s:stage:apply`      |
| prod-1      | `prod-1-platform`     | `task k8s:prod:platform:up` |

stage and prod are co-tenant on the mini-PC (see
`vault/decisions/stage-prod-cotenancy.md`); the two NATS instances are
isolated structurally by namespace, not by topic-name discipline.

## Connection URL (in-cluster)

```
nats://nats.<env-platform-ns>.svc.cluster.local:4222
```

## Smoke test

```sh
kubectl exec -ti deploy/nats-box -n prod-1-platform -- nats pub foo bar
kubectl exec -ti deploy/nats-box -n prod-1-platform -- nats sub foo
```

## Topic convention

Producer-side, not enforced by the broker:

```
tripbot.<env>.<domain>.<event>
```

e.g. `tripbot.prod.onscreens.middle.show`.

## Metrics

The `promExporter` sidecar exposes `nats_*` series on `:7777/metrics`.
Pod-level `prometheus.io/scrape: "true"` annotation routes
alloy-metrics auto-discovery to it (matches the annotation keys in
`k8s/monitoring/<env>/values.yml`).
