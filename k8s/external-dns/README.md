
```bash
$ helm repo add bitnami https://charts.bitnami.com/bitnami
$ helm install dns bitnami/external-dns -c k8s/external-dns/stage-1/config.yml
```
