```bash
helm repo add jetstack https://charts.jetstack.io
helm upgrade --install cert-manager --namespace kube-system jetstack/cert-manager -f k8s/cert-manager/development/config.yml
kubectl apply -k k8s/cert-manager/development
```
