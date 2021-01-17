
```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm upgrade --install dns bitnami/external-dns -f k8s/external-dns/stage-1/config.yml -n kube-system
```
