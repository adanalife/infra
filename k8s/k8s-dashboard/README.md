helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/
helm-stage install k8s-dashboard kubernetes-dashboard/kubernetes-dashboard -n kube-system
