
```bash
# install the secret
cp k8s/external-dns/development/credentials{.example,}
vim k8s/external-dns/development/credentials

helm repo add bitnami https://charts.bitnami.com/bitnami
helm upgrade --install dns bitnami/external-dns -f k8s/external-dns/development/config.yml -n kube-system
kubectl apply -k k8s/external-dns/development
```
