# infra


## running kubernetes locally

Local app stack (postgres + tripbot + vlc-server + obs) on k3d. Manifests
live in `k8s/apps/<component>/{base,overlays/local}/`; the umbrella overlay
at `k8s/overlays/local/` wires them together. The k3d cluster config is at
`k8s/k3d-config.yaml`.

```bash
brew install k3d kubectl

# 1. Fill in secrets (gitignored)
for d in k8s/apps/{postgres,tripbot,obs}/overlays/local; do
  cp $d/secret.env.example $d/secret.env
  $EDITOR $d/secret.env
done

# 2. Bring up the cluster, build & import images, apply manifests
task k8s-up
task k8s-images   # builds via tripbot/infra/docker/docker-compose.yml
task k8s-apply

# 3. Verify
kubectl get pods                              # all four Running
curl -H "Host: tripbot.localhost" http://localhost/health/live
# VNC (optional): vnc://localhost:5902 (obs), vnc://localhost:5903 (vlc)
# RTSP (optional): rtsp://localhost:8554/dashcam

# 4. Tear down
task k8s-down
```

The bundled traefik handles the tripbot Ingress; the bundled servicelb
(klipper-lb) fulfills the VNC/RTSP LoadBalancer services declared in the
local overlays. Both are k3s-only — on EKS the same Ingress works against
prod traefik unchanged, and LoadBalancer services are fulfilled by AWS ELB.



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
