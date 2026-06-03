# infra


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
`kubectl port-forward`. Off-LAN access to the mini-PC envs is via Tailscale
(see `vault/decisions/tailscale-access-model`); the dev k3d cluster is
local-only.

The bundled traefik handles the tripbot Ingress in-cluster; the bundled
servicelb (klipper-lb) fulfills the VNC/RTSP LoadBalancer services declared
by the app manifests. Both are k3s-only — on EKS the same Ingress works
against prod traefik unchanged, and LoadBalancer services are fulfilled by
AWS ELB.



### set up prometheus

```bash
g cl https://github.com/coreos/kube-prometheus
g co release-0.4 # because we were on k8s v1.17
k8s create -f manifests/setup -f manifests # might need to run multiple times
```


### set up aws-vault

```bash
cat ~/.aws/config

[profile adanalife-core]
region=us-east-1
source_profile=adanalife

[profile adanalife-stage]
region=us-east-1
source_profile=adanalife
role_arn=arn:aws:iam::413585268653:role/AdminUser

[profile adanalife-stage-developer]
region=us-east-1
source_profile=adanalife
role_arn=arn:aws:iam::413585268653:role/DeveloperUser

[profile adanalife-prod]
region=us-east-1
source_profile=adanalife
role_arn=arn:aws:iam::704461573429:role/AdminUser

[profile adanalife-prod-developer]
region=us-east-1
source_profile=adanalife
role_arn=arn:aws:iam::704461573429:role/DeveloperUser
```


```bash
cat ~/.bash_profile.local

alias aws-dana-core="aws-vault exec adanalife-core --no-session"
alias aws-dana-stage="aws-vault exec adanalife-stage --no-session"
alias aws-dana-stage-developer="aws-vault exec adanalife-stage-developer --no-session"
alias aws-dana-prod="aws-vault exec adanalife-prod --no-session"
alias aws-dana-prod-developer="aws-vault exec adanalife-prod-developer --no-session"
# alias aws-dana-core-root="aws-vault exec adanalife-root --no-session"

alias login-dana-core="aws-vault login adanalife-core"
alias login-dana-stage="aws-vault login adanalife-stage"
alias login-dana-stage-developer="aws-vault login adanalife-stage-developer --duration=12h"
alias login-dana-prod="aws-vault login adanalife-prod"
alias login-dana-prod-developer="aws-vault login adanalife-prod-developer --duration=12h"
# alias login-dana-root="aws-vault login adanalife-root"

alias tf-dana-core="cd ~/danalol/infra/terraform/core && aws-dana-core"
alias tf-dana-stage="cd ~/danalol/infra/terraform/stage-1 && aws-dana-stage"
alias tf-dana-prod="cd ~/danalol/infra/terraform/prod-1 && aws-dana-prod"

alias k8s-dana-stage="aws-dana-stage -- kubectl"
alias helm-dana-stage="aws-dana-stage -- helm"
```
