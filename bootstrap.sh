#!/bin/bash
# Manual platform-bootstrap recipe (run line-by-line, not as a single
# script — the external-dns block has a "update config.yml with secret
# name" step that requires human attention before the helm install).

# cert-manager
# generate secrets first
kubectl apply -k k8s/cert-manager/stage-1
helm repo add jetstack https://charts.jetstack.io
helm upgrade --install cert-manager jetstack/cert-manager -f k8s/cert-manager/stage-1/config.yml -n kube-system

# traefik
helm repo add traefik https://helm.traefik.io/traefik
helm upgrade --install traefik traefik/traefik -f k8s/traefik/stage-1/config.yml -n kube-system
kubectl apply -k k8s/traefik/stage-1

# external-dns
kubectl apply -k k8s/external-dns/stage-1
# update k8s/external-dns/stage-1/config.yml with secret name...
helm repo add bitnami https://charts.bitnami.com/bitnami
helm upgrade --install dns bitnami/external-dns -f k8s/external-dns/stage-1/config.yml -n kube-system


# k8s-dashboard
helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/
helm upgrade --install k8s-dashboard kubernetes-dashboard/kubernetes-dashboard -f k8s/k8s-dashboard/stage-1/config.yml -n kube-system
kubectl apply -k k8s/k8s-dashboard/stage-1
