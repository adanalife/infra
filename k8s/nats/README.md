# k8s/nats

NATS message bus — deployed per-env via the upstream chart: single-node,
JetStream on (file-backed), prom-exporter sidecar.

## Why NATS

Decouple producer/consumer for inter-component traffic. Fire-and-forget
calls between tripbot, vlc-server, and onscreens-server ride NATS subjects;
queries stay on HTTP. JetStream backs the admin console's chat log and
live-map breadcrumb trail so they survive a tripbot restart (tripbot
declares the `TRIPBOT_CHAT` / `TRIPBOT_VIDEO` streams at startup and
backfills from them).

## Layout

```text
k8s/nats/
├── values.yml              # shared chart values (JetStream on, prom-exporter on)
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

stage and prod are co-tenant on the mini-PC; the two NATS instances are
isolated structurally by namespace, not by topic-name discipline.

## Connection URL (in-cluster)

```text
nats://nats.<env-platform-ns>.svc.cluster.local:4222
```

## Smoke test

The in-cluster `nats-box` pod is disabled (`natsBox.enabled: false`) — it's not
in the data path and clashes with the namespace's restricted Pod Security
Standard. Smoke-test by port-forwarding the server and using a local `nats` CLI:

```sh
kubectl port-forward -n prod-1-platform svc/nats 4222:4222 &
nats pub foo bar    # in another shell; nats sub foo to receive
```

## Topic convention

Producer-side, not enforced by the broker:

```text
tripbot.<env>.<domain>.<event>
```

e.g. `tripbot.prod.onscreens.middle.show`.

## Metrics

The `promExporter` sidecar exposes `nats_*` series on `:7777/metrics`.
Pod-level `prometheus.io/scrape: "true"` annotation routes
alloy-metrics auto-discovery to it (matches the annotation keys in
`k8s/monitoring/<env>/values.yml`).
