```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add stable https://charts.helm.sh/stable
helm repo update
helm install [RELEASE_NAME] prometheus-community/prometheus
```

```bash
helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/
helm install [RELEASE_NAME] kubernetes-dashboard/kubernetes-dashboard

```

