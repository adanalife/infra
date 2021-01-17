# infra


## running kubernetes locally

```bash
brew install k3d
# expose the container's port 80 to localhost:8081
# and mount assets/video to the container's /video
#TODO: pass in rancher/k3s:v1.18.6-k3s1 ??
k3d cluster create adanalife-dev -p 8081:80@loadbalancer --volume $(pwd)/assets/video:/video
# set up kubectl to use this cluster
export KUBECONFIG="$(k3d kubeconfig merge adanalife-dev)"
# create local tripbot deployment
kubectl apply -k infra/k8s/tripbot/stage-1/
curl localhost:8081
```



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
```


```bash
cat ~/.bash_profile.local

alias aws-dana-core="aws-vault exec adanalife-core --no-session"
alias aws-dana-stage="aws-vault exec adanalife-stage --no-session"
alias aws-dana-stage-developer="aws-vault exec adanalife-stage-developer --no-session"
# alias aws-dana-core-root="aws-vault exec adanalife-root --no-session"

alias login-dana-core="aws-vault login adanalife-core"
alias login-dana-stage="aws-vault login adanalife-stage"
alias login-dana-stage-developer="aws-vault login adanalife-stage-developer --duration=12h"
# alias login-dana-root="aws-vault login adanalife-root"

alias tf-dana-core="cd ~/danalol/tripbot/infra/terraform/core && aws-dana-core"
alias tf-dana-stage="cd ~/danalol/tripbot/infra/terraform/stage-1 && aws-dana-stage"
```
