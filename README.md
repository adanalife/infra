# infra

Infrastructure-as-code for [A Dana Life](https://dana.lol): terraform for the
cloud accounts (AWS, GCP, Cloudflare, Tailscale, GitHub), cdk8s + Argo CD for
the Kubernetes app manifests, and a Taskfile that ties the workflows together.

## running kubernetes locally (development / bees)

Dev app stack (postgres + tripbot + vlc-server + obs + onscreens-server) on a
local k3d cluster ("bees"). The manifests are authored in cdk8s
(`cdk8s/adanalife_k8s/`) and synthesized to `cdk8s/dist/development-*.k8s.yaml`.
dev is **not** Argo-managed, so it deploys with a direct `kubectl apply` via
`task cdk8s:dev:apply`. The k3d cluster config is at `k8s/k3d-config.bees.yaml`.

> prod-1/stage-1 app workloads are delivered by Argo CD from `cdk8s/dist/`
> instead — see `gitops/README.md`.

```bash
brew install k3d kubectl

# 1. Bring up the cluster and seed the ESO bootstrap Secret
task k8s:dev:cluster:up
task k8s:dev:bootstrap-secrets

# 2. Build & import images, then deploy the synthesized manifests
task k8s:import-images   # builds via tripbot/infra/docker/docker-compose.yml
task cdk8s:dev:apply     # data (postgres + SecretStore), then apps

# 3. Verify
kubectl get pods                              # all four Running
kubectl port-forward svc/tripbot 8080:80 &    # ad-hoc HTTP to tripbot
curl http://localhost:8080/health/live
# VNC (optional): kubectl port-forward svc/obs 5902:5902 → vnc://localhost:5902
#                 kubectl port-forward svc/vlc-server 5903:5903 → vnc://localhost:5903
# RTSP (optional): kubectl port-forward svc/vlc-server 8554:8554 → rtsp://localhost:8554/dashcam

# 4. Tear down
task k8s:dev:cluster:down
```

The k3d cluster has no host-port bindings (see `k8s/k3d-config.bees.yaml`)
— anything you want to reach from the laptop goes through
`kubectl port-forward`. Off-LAN access to the mini-PC envs is via Tailscale;
the dev k3d cluster is local-only.

The bundled traefik handles the tripbot Ingress in-cluster; the bundled
servicelb (klipper-lb) fulfills the VNC/RTSP LoadBalancer services declared
by the app manifests. Both are k3s-only — on EKS the same Ingress works
against prod traefik unchanged, and LoadBalancer services are fulfilled by
AWS ELB.
