```bash
helm repo add jetstack https://charts.jetstack.io
helm install cert-manager --namespace kube-system jetstack/cert-manager -k k8s/cert-manager/stage-1
```
