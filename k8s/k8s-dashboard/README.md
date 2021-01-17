helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/
helm install k8s-dashboard kubernetes-dashboard/kubernetes-dashboard -n kube-system -f k8s/k8s-dashboard/stage-1/config.yml

Get the Kubernetes Dashboard URL by running:
  export POD_NAME=$(kubectl get pods -n kube-system -l "app.kubernetes.io/name=kubernetes-dashboard,app.kubernetes.io/instance=k8s-dashboard" -o jsonpath="{.items[0].metadata.name}")
  echo https://127.0.0.1:8443/
  kubectl -n kube-system port-forward $POD_NAME 8443:8443
