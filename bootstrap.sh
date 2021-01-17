# unfuck traefik
g co -- k8s/traefik/stage-1/values.yml

# external-dns
helm repo add bitnami https://charts.bitnami.com/bitnami
helm upgrade --install dns bitnami/external-dns -f k8s/external-dns/stage-1/config.yml -n kube-system

# cert-manager
helm repo add jetstack https://charts.jetstack.io
helm upgrade --install cert-manager --namespace kube-system jetstack/cert-manager -f k8s/cert-manager/stage-1/config.yml

# k8s-dashboard
helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/
helm upgrade --install k8s-dashboard kubernetes-dashboard/kubernetes-dashboard -n kube-system -f k8s/k8s-dashboard/stage-1/config.yml
kubectl apply -k k8s/k8s-dashboard/stage-1
