#!/bin/bash
# Bootstrap script - run on a fresh cluster to deploy all infrastructure and apps.
# Prerequisites:
#   - kubectl configured against the target cluster
#   - helm installed
#
# ============================================================
# MANUAL SECRETS (from Vaultwarden) — create BEFORE running:
# ============================================================
#
#   ceph-csi-rbd namespace:
#     kubectl create secret generic csi-rbd-secret -n ceph-csi-rbd \
#       --from-literal=userID=kubernetes \
#       --from-literal=userKey=<key from Vaultwarden: ceph-csi-rbd>
#
#   cert-manager namespace:
#     kubectl create secret generic cloudflare-api-token -n cert-manager \
#       --from-literal=api-token=<token from Vaultwarden: cloudflare-api-token>
#
#   monitoring namespace:
#     kubectl create secret generic grafana-authentik-secret -n monitoring \
#       --from-literal=client_id=<id> \
#       --from-literal=client_secret=<secret from Vaultwarden: grafana-authentik>
#
#   authentik namespace:
#     kubectl create secret generic authentik-secret -n authentik \
#       --from-literal=AUTHENTIK_SECRET_KEY=<key> \
#       --from-literal=AUTHENTIK_POSTGRESQL__PASSWORD=<password> \
#       ... (see Vaultwarden: authentik-secret)
#
#   external-secrets namespace (ESO machine identity for Infisical):
#     kubectl create namespace external-secrets
#     kubectl create secret generic infisical-machine-identity -n external-secrets \
#       --from-literal=clientId=1a5f2d02-e826-4132-9784-aa8e23094416 \
#       --from-literal=clientSecret=<secret from Vaultwarden: eso-k8s-machine-identity>
#
#   argocd namespace (AFTER ArgoCD is installed — not ESO-managed):
#     kubectl -n argocd patch secret argocd-secret \
#       -p '{"stringData":{"dex.authentik.clientSecret":"<secret from Vaultwarden: argocd-dex>"}}'
#
# ============================================================
# ESO-MANAGED SECRETS (auto-created via Infisical after ESO deploys):
# ============================================================
#   All other secrets (vaultwarden, nextcloud, harbor, pgadmin, immich,
#   infisical, apicurio, cnpg-clusters, etc.) are managed by ESO ExternalSecrets
#   pointing to Infisical. They sync automatically once ESO + Infisical are up.
#   Add eso-k8s machine identity to Infisical project members in UI (not just org-level).
#
# ============================================================
# NOTE: sync-wave annotations on each argocd-app-*.yaml control ordering.
#       When you add a new app, add BOTH the manifest in the repo AND
#       a matching kubectl apply line here, or it won't deploy on a fresh cluster.
# ============================================================
set -e

echo "Installing/upgrading ArgoCD..."
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm upgrade --install argocd argo/argo-cd \
  -n argocd --create-namespace \
  --version 9.5.15 \
  -f infrastructure/argocd/values.yaml
kubectl -n argocd wait deploy/argocd-server --for=condition=available --timeout=300s

echo "Applying infrastructure apps (wave 0 — storage/network foundation)..."
kubectl apply -f infrastructure/metallb/argocd-app-metallb.yaml
kubectl apply -f infrastructure/ceph-csi/argocd-app-ceph-csi.yaml

echo "Applying infrastructure apps (wave 1 — CNI, ingress, TLS)..."
kubectl apply -f infrastructure/cilium/argocd-app-cilium.yaml
kubectl apply -f infrastructure/cert-manager/argocd-app-cert-manager.yaml
kubectl apply -f infrastructure/ingress-nginx/argocd-app-ingress-nginx.yaml

echo "Applying infrastructure apps (wave 2 — config that depends on wave 1 CRDs)..."
kubectl apply -f infrastructure/metallb/argocd-app-metallb-config.yaml
kubectl apply -f infrastructure/cert-manager/argocd-app-cert-manager-config.yaml

echo "Applying infrastructure apps (wave 3 — cluster operations)..."
kubectl apply -f infrastructure/reflector/argocd-app-reflector.yaml
kubectl apply -f infrastructure/reloader/argocd-app-reloader.yaml
kubectl apply -f infrastructure/kured/argocd-app-kured.yaml
kubectl apply -f infrastructure/descheduler/argocd-app-descheduler.yaml
kubectl apply -f infrastructure/keda/argocd-app-keda.yaml
kubectl apply -f infrastructure/argo-rollouts/argocd-app-argo-rollouts.yaml
kubectl apply -f infrastructure/network-policies/argocd-app-network-policies.yaml

echo "Applying infrastructure apps (wave 4 — platform services)..."
kubectl apply -f infrastructure/authentik/argocd-app-authentik.yaml
kubectl apply -f infrastructure/monitoring/argocd-app-monitoring.yaml
kubectl apply -f infrastructure/tempo/argocd-app-tempo.yaml
kubectl apply -f infrastructure/velero/argocd-app-velero.yaml

echo "Applying infrastructure apps (wave 5 — observability and cluster UI)..."
kubectl apply -f infrastructure/loki/argocd-app-loki.yaml
kubectl apply -f infrastructure/loki/argocd-app-promtail.yaml
kubectl apply -f infrastructure/headlamp/argocd-app-headlamp.yaml
kubectl apply -f infrastructure/goldilocks/argocd-app-goldilocks.yaml

echo "Applying infrastructure apps (wave 6 — secrets management)..."
kubectl apply -f infrastructure/eso/argocd-app-eso.yaml
kubectl apply -f infrastructure/infisical/argocd-app-infisical.yaml
echo "  --> Wait for ESO + Infisical to be ready before continuing"
echo "  --> Add eso-k8s machine identity to Infisical project members in UI"
echo "  --> ESO ClusterSecretStore will then sync all app secrets automatically"

echo "Applying infrastructure apps (wave 7 — CNPG)..."
kubectl apply -f infrastructure/cnpg/argocd-app-cnpg.yaml
kubectl apply -f infrastructure/cnpg-clusters/argocd-app-cnpg-clusters.yaml

echo "Applying infrastructure apps (wave 8 — harbor, actions runners)..."
kubectl apply -f infrastructure/harbor/argocd-app-harbor.yaml
kubectl apply -f infrastructure/actions-runner/argocd-app-actions-runner-controller.yaml
kubectl apply -f infrastructure/actions-runner/argocd-app-runners-k8s-apps.yaml
kubectl apply -f infrastructure/actions-runner/argocd-app-runners-yana-ecommerce.yaml
kubectl apply -f infrastructure/actions-runner/argocd-app-runners-yana-forex.yaml

echo "Applying apps (wave 9 — foundational apps)..."
kubectl apply -f apps/vaultwarden/argocd-app-vaultwarden.yaml
kubectl apply -f apps/kafka/argocd-app-strimzi.yaml

echo "Applying apps (wave 10 — all other apps)..."
kubectl apply -f apps/kafka/argocd-app-kafka.yaml
kubectl apply -f apps/kafka-ui/argocd-app-kafka-ui.yaml
kubectl apply -f apps/uptime-kuma/argocd-app-uptime-kuma.yaml
kubectl apply -f apps/pgadmin/argocd-app-pgadmin.yaml
kubectl apply -f apps/nextcloud/argocd-app-nextcloud.yaml
kubectl apply -f apps/gotify/argocd-app-gotify.yaml
kubectl apply -f apps/apicurio/argocd-app-apicurio.yaml
kubectl apply -f apps/kubernetes-dashboard/argocd-app-kubernetes-dashboard.yaml

echo "Bootstrapping Immich (CNPG cluster + PVC must exist before Helm app)..."
kubectl apply -f apps/immich/namespace.yaml
kubectl apply -f apps/immich/external-secret.yaml
echo "  --> Wait for immich-secrets and immich-db-credentials to sync from ESO"
echo "  --> Then run: kubectl get externalsecret -n immich"
kubectl apply -f apps/immich/postgres-cluster.yaml
kubectl apply -f apps/immich/library-pvc.yaml
echo "  --> Wait for immich-postgres cluster to be Healthy and PVCs to be Bound"
echo "  --> Then run: kubectl get cluster immich-postgres -n immich"
kubectl apply -f apps/immich/argocd-app-immich.yaml
kubectl apply -f apps/immich/argocd-app-immich-helm.yaml

echo ""
echo "============================================================"
echo "Done. ArgoCD will sync everything automatically."
echo ""
echo "Post-bootstrap manual steps:"
echo "  1. Patch ArgoCD dex secret:"
echo "     kubectl -n argocd patch secret argocd-secret \\"
echo "       -p '{\"stringData\":{\"dex.authentik.clientSecret\":\"<secret from Vaultwarden: argocd-dex>\"}}'"
echo "  2. Headlamp SA token (SSO broken upstream — use SA token instead):"
echo "     kubectl create token headlamp -n headlamp --duration=8760h"
echo "  3. Set up Immich admin account at https://photos.yanatech.co.uk"
echo "  4. Configure Immich Authentik SSO in Immich admin UI → Administration → Settings → OAuth"
echo "============================================================"

