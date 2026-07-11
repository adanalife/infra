# infra

Infrastructure-as-code for [A Dana Life](https://dana.lol): terraform for the
cloud accounts (AWS, GCP, Cloudflare, Tailscale, GitHub), cdk8s + Argo CD for
the Kubernetes platform and supporting manifests (app manifests live in each
app's own repo), and a Taskfile that ties the workflows together.

## running kubernetes locally (development)

Dev app stack (postgres + tripbot + vlc-server + obs + onscreens-server) on a
local k3d cluster (`adanalife-dev`). The infra manifests are authored in cdk8s
(`cdk8s/adanalife_k8s/`) and synthesized to `cdk8s/dist/development-*.k8s.yaml`;
the tripbot app manifests live in the tripbot repo (obs manifests in the obs
repo) and are delivered by dev's own in-cluster Argo CD. The k3d cluster config is at `k8s/k3d-config.yaml`.

> prod-1/stage-1 app workloads are delivered by Argo CD from `cdk8s/dist/`
> instead — see `gitops/README.md`.

Prereqs: `brew install k3d kubectl helm argocd go-task/tap/go-task`, Colima/Docker
running, `aws-vault` profiles for `adanalife-stage` (dev borrows the stage AWS
account for ESO), and the **Keybase app running + logged in** (it pgp-decrypts the
ESO bootstrap creds — `open -a Keybase` and wait ~10s if the daemon is down).

```bash
# Cold-start the whole env from nothing (creates the adanalife-dev cluster,
# installs the platform stack + Argo CD, then Argo-syncs the apps in order):
task k8s:dev:up

# Iterate on a LOCAL build — builds the image, imports it as :dev-local, and
# pins the live Deployment to it (pauses Argo selfHeal so it sticks). APP=<app>
# for one of tripbot|vlc|obs|onscreens; omit for all four:
task k8s:dev:deploy APP=tripbot

# Revert to CI's :main image (re-enables selfHeal + re-syncs):
task k8s:dev:sync

# At a glance: pods, the image tag each app runs, and Argo app health:
task k8s:dev:status

# Tear down:
task k8s:dev:down
```

A fresh cluster cold-starts on CI's `adanalife/*:main` images from the
registry (so `k8s:dev:up` just works); `k8s:dev:deploy` is only for running a
local build. While you're iterating on `:dev-local`, Argo shows the app
`OutOfSync` — that's expected; `k8s:dev:sync` clears it.

Ad-hoc access (no host-port bindings on the dev cluster — everything is
`kubectl port-forward`):

```bash
kubectl port-forward -n development svc/tripbot-twitch 8080:8080 &
curl http://localhost:8080/health/live
# VNC:  kubectl port-forward -n development svc/obs-twitch 5902:5902  → vnc://localhost:5902
#       kubectl port-forward -n development svc/vlc-twitch 5903:5903  → vnc://localhost:5903
# RTSP: kubectl port-forward -n development svc/vlc-twitch 8554:8554  → rtsp://localhost:8554/dashcam
```

The k3d cluster has no host-port bindings (see `k8s/k3d-config.yaml`)
— anything you want to reach from the laptop goes through
`kubectl port-forward`. Off-LAN access to the mini-PC envs is via Tailscale;
the dev k3d cluster is local-only.

The bundled traefik handles the tripbot Ingress in-cluster; the bundled
servicelb (klipper-lb) fulfills the VNC/RTSP LoadBalancer services declared
by the app manifests. Both are k3s-only — stage-1/prod-1 co-tenant a bare-metal
Talos cluster on a mini-PC with no LoadBalancer controller; traefik there runs
on hostNetwork, binding the node's LAN IP :80/:443.
