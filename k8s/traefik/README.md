```bash
helm repo add traefik https://helm.traefik.io/traefik
helm upgrade --install traefik traefik/traefik -f k8s/traefik/stage-1/config.yml -n kube-system
```
