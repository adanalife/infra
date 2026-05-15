# Traefik

In-cluster ingress controller, installed via `traefik/traefik` helm chart by `task k8s:stage:platform:up`. Replaces the k3s-bundled Traefik (disabled in `k8s/k3d-config.bees.yaml` via `--disable=traefik`).

App Ingresses opt in via `ingressClassName: traefik` (e.g. `k8s/apps/tripbot/base/ingress.yaml`). The release also registers itself as the default IngressClass for any Ingress that doesn't specify one.

## Dashboard

Enabled with `--api.insecure=true` for laptop-loopback access — fine for k3d, would need replacing with an auth-protected IngressRoute on a real public cluster.

```sh
kubectl -n kube-system port-forward svc/traefik 9000:9000
open http://localhost:9000/dashboard/
```

(The trailing slash matters — Traefik's dashboard handler is strict about it.)

## Metrics

Pod-level `prometheus.io/scrape` annotations let `grafana-k8s-monitoring`'s `annotationAutodiscovery` feature scrape Traefik's `/metrics` endpoint on port 9100. Per-router/service labels are enabled, so latency breakdowns per Ingress are queryable in Grafana Cloud Mimir.
