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
task k8s-import-images   # builds via tripbot/infra/docker/docker-compose.yml
task k8s-apply

# 3. Verify
kubectl get pods                              # all four Running
kubectl port-forward svc/tripbot 8080:80 &    # ad-hoc HTTP to tripbot
curl http://localhost:8080/health/live
# VNC (optional): kubectl port-forward svc/obs 5902:5902 → vnc://localhost:5902
#                 kubectl port-forward svc/vlc-server 5903:5903 → vnc://localhost:5903
# RTSP (optional): kubectl port-forward svc/vlc-server 8554:8554 → rtsp://localhost:8554/dashcam

# 4. Tear down
task k8s-down
```

The k3d cluster has no host-port bindings (see `k8s/k3d-config.yaml`)
— anything you want to reach from the laptop goes through
`kubectl port-forward`, and stage-1 mode (next section) handles
public exposure through a Cloudflare Tunnel.

The bundled traefik handles the tripbot Ingress in-cluster; the bundled
servicelb (klipper-lb) fulfills the VNC/RTSP LoadBalancer services
declared in the local overlays. Both are k3s-only — on EKS the same
Ingress works against prod traefik unchanged, and LoadBalancer services
are fulfilled by AWS ELB.


## exposing services publicly (stage-1 mode)

Wires the cluster to a Cloudflare Tunnel — TLS and IP allowlisting are
handled at the Cloudflare edge, no port-forwarding, no in-cluster certs.
DNS lives on Cloudflare under `whalecore.com`, our dedicated stage-1 /
experimental domain; nothing about this touches the Route53 zones for
`whereisdana.today` or `dana.lol`. Cloudflare resources live alongside
AWS resources in `terraform/stage-1/` (`cloudflare-*.tf`); the Cloudflare
API token and the home-IP allowlist are stored in AWS Secrets Manager.

```bash
# 1. First-time only — enable Cloudflare Access (Zero Trust) at
#    https://dash.cloudflare.com → Zero Trust. Free tier; pick a team
#    name. Required before Access policies can be created.

# 2. First apply — creates the SM secret containers (with placeholders)
#    and the AWS resources. Cloudflare resources fail because the
#    placeholder token can't authenticate. Expected.
task tf-stage

# 3. Populate the secrets out-of-band. The Cloudflare API token needs
#    these scopes: Zone:Edit, Tunnel:Edit, Pages:Edit, Access:Apps and
#    Policies:Edit, DNS:Edit, Zone Settings:Edit.
aws-vault exec adanalife-stage -- aws secretsmanager put-secret-value \
  --secret-id stage-1/cloudflare-api-token --secret-string "$CLOUDFLARE_API_TOKEN"
task update-home-ip   # opens stage-1/home-cidrs in $EDITOR; JSON array of CIDRs

# 4. Second apply — creates the whalecore.com zone, tunnel, ingress
#    config, DNS record, Access app + IP allow policy, and the Pages
#    project.
task tf-stage

# 5. First-time only — point whalecore.com's nameservers at Cloudflare.
#    Get the values from terraform output:
aws-vault exec adanalife-stage -- sh -c 'cd terraform/stage-1 \
  && terraform output -json stage_1_zone_name_servers | jq -r ".[]"'
#    Update the NS records at whalecore.com's registrar to those values.
#    Cloudflare will mark the zone "Active" once propagation completes
#    (minutes to hours).

# 6. Write the tunnel token from terraform output into the kustomize
#    secret.env (re-run any time the tunnel is recreated).
task k8s-tunnel-token

# 7. Apply the stage-1 overlay — same four apps as `task k8s-apply`,
#    plus the cloudflared Deployment.
task k8s-apply-stage-1

# 8. Verify (after Cloudflare marks the zone Active in step 5).
curl https://tripbot.whalecore.com/health/live
#   from an allowlisted IP → 200 OK
#   from a non-allowlisted IP → Cloudflare Access challenge page
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
