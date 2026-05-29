#!/bin/bash
# Bootstrap script - run after installing ArgoCD on a fresh cluster
# Apply manual secrets first (see each README.md)

set -e

echo "Applying infrastructure apps..."
kubectl apply -f infrastructure/metallb/argocd-app-metallb.yaml
kubectl apply -f infrastructure/metallb/argocd-app-metallb-config.yaml
kubectl apply -f infrastructure/cert-manager/argocd-app-cert-manager-config.yaml
kubectl apply -f infrastructure/ingress-nginx/argocd-app-ingress-nginx.yaml
kubectl apply -f infrastructure/reflector/argocd-app-reflector.yaml
kubectl apply -f infrastructure/ceph-csi/argocd-app-ceph-csi.yaml
kubectl apply -f infrastructure/monitoring/argocd-app-monitoring.yaml
kubectl apply -f infrastructure/authentik/argocd-app-authentik.yaml
kubectl apply -f infrastructure/velero/argocd-app-velero.yaml

echo "Applying apps..."
kubectl apply -f apps/vaultwarden/argocd-app-vaultwarden.yaml
kubectl apply -f apps/kafka/argocd-app-strimzi.yaml
kubectl apply -f apps/kafka/argocd-app-kafka.yaml

echo "Done. ArgoCD will sync everything automatically."
