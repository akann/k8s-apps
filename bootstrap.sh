#!/bin/bash
# Bootstrap script - run on a fresh cluster to deploy all infrastructure and apps.
# Prerequisites:
#   - kubectl configured against the target cluster
#   - helm installed
#   - Manual secrets created BEFORE running this script (all stored in Vaultwarden):
#
#   ceph-csi-rbd namespace:
#     csi-rbd-secret (Ceph client.kubernetes key)
#
#   cert-manager namespace:
#     cloudflare-api-token (Cloudflare API token)
#
#   monitoring namespace:
#     grafana-authentik-secret (client_id, client_secret)
#
#   authentik namespace:
#     authentik-secret (DB host/name/user/password, secret key)
#
#   argocd namespace:
#     kubectl -n argocd patch secret argocd-secret -p '{"stringData":{"dex.authentik.clientSecret":"<secret>"}}'
#
#   vaultwarden namespace:
#     vaultwarden-secret (DATABASE_URL, ADMIN_TOKEN, DOMAIN)
#
#   velero namespace:
#     velero-b2-credentials (Backblaze B2 keyID + applicationKey)
#
#   pgadmin namespace:
#     pgadmin-oauth-secret (OAUTH2_CLIENT_ID, OAUTH2_CLIENT_SECRET)
#     pgadmin-config-local ConfigMap with config_local.py
#
#   nextcloud namespace:
#     nextcloud-secret (nextcloud-username, nextcloud-password, nextcloud-token, db-username, db-password)
#
#   gotify namespace:
#     gotify-secret (admin-password)
#
#   immich namespace:
#     immich-secret (db-url: postgresql://immich:<password>@192.168.22.40:5432/immich)
#     immich-library PVC (500Gi ceph-rbd) — must exist before ArgoCD syncs immich:
#       kubectl apply -f - <<PVCEOF
#       apiVersion: v1
#       kind: PersistentVolumeClaim
#       metadata:
#         name: immich-library
#         namespace: immich
#       spec:
#         accessModes: [ReadWriteOnce]
#         storageClassName: ceph-rbd
#         resources:
#           requests:
#             storage: 500Gi
#       PVCEOF
#
# pg1 prerequisites (192.168.22.40) — must be done before deploying immich:
#   - postgresql-18-pgvector and VectorChord 1.1.1 installed
#   - shared_preload_libraries = 'vchord.so' in postgresql.conf
#   - Extensions cube, earthdistance, vector, vchord created in immich DB as superuser
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
kubectl apply -f infrastructure/loki/argocd-app-loki.yaml
kubectl apply -f infrastructure/loki/argocd-app-promtail.yaml
kubectl apply -f infrastructure/reloader/argocd-app-reloader.yaml
kubectl apply -f infrastructure/kured/argocd-app-kured.yaml
kubectl apply -f infrastructure/goldilocks/argocd-app-goldilocks.yaml
kubectl apply -f infrastructure/descheduler/argocd-app-descheduler.yaml

echo "Applying apps..."
kubectl apply -f apps/uptime-kuma/argocd-app-uptime-kuma.yaml
kubectl apply -f apps/vaultwarden/argocd-app-vaultwarden.yaml
kubectl apply -f apps/kafka/argocd-app-strimzi.yaml
kubectl apply -f apps/kafka/argocd-app-kafka.yaml
kubectl apply -f apps/kafka-ui/argocd-app-kafka-ui.yaml
kubectl apply -f apps/pgadmin/argocd-app-pgadmin.yaml
kubectl apply -f apps/nextcloud/argocd-app-nextcloud.yaml
kubectl apply -f apps/gotify/argocd-app-gotify.yaml
kubectl apply -f apps/immich/argocd-app-immich.yaml

echo "Done. ArgoCD will sync everything automatically."
