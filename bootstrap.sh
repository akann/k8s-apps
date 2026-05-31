#!/bin/bash
# Bootstrap script - run on a fresh cluster to deploy all infrastructure and apps.
# Prerequisites:
#   - kubectl configured against the target cluster
#   - helm installed
#   - Manual secrets created BEFORE running this script (see each app's README):
#       argocd:      kubectl -n argocd patch secret argocd-secret with dex.authentik.clientSecret
#       monitoring:  grafana-authentik-secret (client_id, client_secret)
#       authentik:   authentik-secret (DB creds, Redis host, secret key)
#       vaultwarden: vaultwarden-secret (DATABASE_URL, ADMIN_TOKEN, DOMAIN)
#
# NOTE: this script enumerates every ArgoCD Application explicitly.
#       When you add a new app, add BOTH the manifest in the repo AND
#       a matching kubectl apply line here, or it won't deploy on a fresh cluster.
set -e

echo "Installing/upgrading ArgoCD..."
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm upgrade --install argocd argo/argo-cd \
  -n argocd --create-namespace \
  --version 9.5.15 \
  -f infrastructure/argocd/values.yaml
kubectl -n argocd wait deploy/argocd-server --for=condition=available --timeout=300s

echo "Applying infrastructure apps..."
kubectl apply -f infrastructure/metallb/argocd-app-metallb.yaml
kubectl apply -f infrastructure/metallb/argocd-app-metallb-config.yaml
kubectl apply -f infrastructure/cert-manager/argocd-app-cert-manager.yaml
kubectl apply -f infrastructure/cert-manager/argocd-app-cert-manager-config.yaml
kubectl apply -f infrastructure/ingress-nginx/argocd-app-ingress-nginx.yaml
kubectl apply -f infrastructure/reflector/argocd-app-reflector.yaml
kubectl apply -f infrastructure/ceph-csi/argocd-app-ceph-csi.yaml
kubectl apply -f infrastructure/monitoring/argocd-app-monitoring.yaml
kubectl apply -f infrastructure/headlamp/argocd-app-headlamp.yaml
kubectl apply -f infrastructure/authentik/argocd-app-authentik.yaml
kubectl apply -f infrastructure/velero/argocd-app-velero.yaml

echo "Applying apps..."
kubectl apply -f apps/uptime-kuma/argocd-app-uptime-kuma.yaml
kubectl apply -f apps/vaultwarden/argocd-app-vaultwarden.yaml
kubectl apply -f apps/kafka/argocd-app-strimzi.yaml
kubectl apply -f apps/kafka/argocd-app-kafka.yaml
kubectl apply -f apps/kafka-ui/argocd-app-kafka-ui.yaml

echo "Done. ArgoCD will sync everything automatically."
