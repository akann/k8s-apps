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
#   argocd namespace — private-repo git credentials (repository-type Secrets,
#   type: git, fine-grained PAT per repo, NOT ESO-managed):
#     kubectl create secret generic repo-akan -n argocd \
#       --from-literal=type=git --from-literal=url=https://github.com/akann/akan \
#       --from-literal=username=<user> --from-literal=password=<PAT from Vaultwarden: repo-akan>
#     kubectl label secret repo-akan -n argocd argocd.argoproj.io/secret-type=repository
#     kubectl create secret generic repo-shared-services -n argocd \
#       --from-literal=type=git --from-literal=url=https://github.com/akann/shared-services \
#       --from-literal=username=<user> --from-literal=password=<PAT from Vaultwarden: repo-shared-services>
#     kubectl label secret repo-shared-services -n argocd argocd.argoproj.io/secret-type=repository
#     kubectl create secret generic repo-ml -n argocd \
#       --from-literal=type=git --from-literal=url=https://github.com/akann/ml \
#       --from-literal=username=<user> --from-literal=password=<PAT from Vaultwarden: repo-ml>
#     kubectl label secret repo-ml -n argocd argocd.argoproj.io/secret-type=repository
#     kubectl create secret generic repo-dove-house-tt -n argocd \
#       --from-literal=type=git --from-literal=url=https://github.com/akann/dove-house-tt \
#       --from-literal=username=<user> --from-literal=password=<PAT from Vaultwarden: repo-dove-house-tt>
#     kubectl label secret repo-dove-house-tt -n argocd argocd.argoproj.io/secret-type=repository
#   Without these, akan/shared-services/ml/dove-house-tt(-stg) Applications fail
#   with "ComparisonError: ... authentication required: Repository not found."
#
#   dove-house-tt + dove-house-tt-stg namespaces — ghcr.io pull secret
#   (images are private; Secrets don't cross namespaces, so create in both):
#     kubectl create secret docker-registry ghcr-secret -n dove-house-tt \
#       --docker-server=ghcr.io --docker-username=<user> \
#       --docker-password=<PAT from Vaultwarden: ghcr-pull-token>
#     kubectl create secret docker-registry ghcr-secret -n dove-house-tt-stg \
#       --docker-server=ghcr.io --docker-username=<user> \
#       --docker-password=<PAT from Vaultwarden: ghcr-pull-token>
#
# ============================================================
# ESO-MANAGED SECRETS (auto-created via Infisical after ESO deploys):
# ============================================================
#   All other secrets (vaultwarden, nextcloud, harbor, pgadmin, immich,
#   infisical, apicurio, cnpg-clusters, redis, mongodb, etc.) are managed
#   by ESO ExternalSecrets pointing to Infisical. They sync automatically
#   once ESO + Infisical are up.
#   Add eso-k8s machine identity to Infisical project members in UI (not just org-level).
#
# ============================================================
# INFISICAL FOLDERS — create before ESO syncs:
# ============================================================
#   infisical secrets folders create --name="redis" --path="/" --env="prod" --projectId="69b39965-b778-47a7-ba52-2cd66a7aad0a"
#   infisical secrets folders create --name="mongodb" --path="/" --env="prod" --projectId="69b39965-b778-47a7-ba52-2cd66a7aad0a"
#   # Set secrets:
#   infisical secrets set REDIS_PASSWORD="$(openssl rand -hex 16)" --projectId 69b39965-b778-47a7-ba52-2cd66a7aad0a --env prod --path /redis
#   infisical secrets set MONGODB_ROOT_PASSWORD="$(openssl rand -hex 16)" --projectId 69b39965-b778-47a7-ba52-2cd66a7aad0a --env prod --path /mongodb
#   infisical secrets set MONGODB_PASSWORD="$(openssl rand -hex 16)" --projectId 69b39965-b778-47a7-ba52-2cd66a7aad0a --env prod --path /mongodb
#   infisical secrets set MONGODB_REPLICA_SET_KEY="$(openssl rand -hex 32)" --projectId 69b39965-b778-47a7-ba52-2cd66a7aad0a --env prod --path /mongodb
#
# ============================================================
# POST-INSTALL MANUAL STEPS:
# ============================================================
#   1. Patch ArgoCD dex secret:
#      kubectl -n argocd patch secret argocd-secret \
#        -p '{"stringData":{"dex.authentik.clientSecret":"<secret from Vaultwarden: argocd-dex>"}}'
#   2. Patch infisical ingress to use nginx class (bundled nginx is disabled):
#      kubectl delete validatingwebhookconfiguration infisical-ingress-nginx-admission 2>/dev/null; true
#      kubectl patch ingress infisical-ingress -n infisical --type='json' \
#        -p='[{"op":"replace","path":"/spec/ingressClassName","value":"nginx"},{"op":"add","path":"/spec/tls","value":[{"hosts":["infisical.yanatech.co.uk"],"secretName":"wildcard-yanatech-tls"}]},{"op":"replace","path":"/spec/rules","value":[{"host":"infisical.yanatech.co.uk","http":{"paths":[{"path":"/","pathType":"Prefix","backend":{"service":{"name":"infisical-infisical-standalone-infisical","port":{"number":8080}}}}]}}]}]'
#   3. Set infisical webhook failurePolicy to Ignore:
#      kubectl patch validatingwebhookconfiguration infisical-ingress-nginx-admission \
#        --type='json' -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]'
#   4. Headlamp SA token (SSO broken upstream):
#      kubectl create token headlamp -n headlamp --duration=8760h
#   5. Set up Immich admin account at https://photos.yanatech.co.uk
#   6. Configure Immich Authentik SSO in Immich admin UI → Administration → Settings → OAuth
#   7. Set up RedisInsight connection: host redis-master.redis.svc.cluster.local, port 6379
#   8. Set up Mongo Express Authentik outpost in Authentik UI
#   9. Set up RedisInsight Authentik outpost in Authentik UI
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
kubectl apply -f infrastructure/cilium/argocd-app-cilium-policies.yaml
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
kubectl apply -f infrastructure/monitoring/argocd-app-grafana-dashboards.yaml
kubectl apply -f infrastructure/monitoring/argocd-app-monitoring-rules.yaml
kubectl apply -f infrastructure/tempo/argocd-app-tempo.yaml
kubectl apply -f infrastructure/velero/argocd-app-velero.yaml

echo "Applying infrastructure apps (wave 5 — observability and cluster UI)..."
kubectl apply -f infrastructure/loki/argocd-app-loki.yaml
kubectl apply -f infrastructure/loki/argocd-app-promtail.yaml
kubectl apply -f infrastructure/headlamp/argocd-app-headlamp.yaml
kubectl apply -f infrastructure/goldilocks/argocd-app-goldilocks.yaml
kubectl apply -f infrastructure/redis/argocd-app-redis.yaml
kubectl apply -f infrastructure/mongodb/argocd-app-mongodb.yaml
kubectl apply -f infrastructure/minio/argocd-app-minio.yaml
kubectl apply -f infrastructure/kong/argocd-app-kong.yaml

echo "Applying infrastructure apps (wave 6 — secrets management)..."
kubectl apply -f infrastructure/eso/argocd-app-eso.yaml
kubectl apply -f infrastructure/infisical/argocd-app-infisical.yaml
kubectl apply -f infrastructure/redis-insight/argocd-app-redis-insight.yaml
kubectl apply -f infrastructure/mongo-express/argocd-app-mongo-express.yaml
echo "  --> Wait for ESO + Infisical to be ready before continuing"
echo "  --> Add eso-k8s machine identity to Infisical project members in UI"
echo "  --> ESO ClusterSecretStore will then sync all app secrets automatically"
echo "  --> Patch infisical ingress manually (see POST-INSTALL MANUAL STEPS above)"

echo "Applying infrastructure apps (wave 7 — CNPG)..."
kubectl apply -f infrastructure/cnpg/argocd-app-cnpg.yaml
kubectl apply -f infrastructure/cnpg-clusters/argocd-app-cnpg-clusters.yaml

echo "Applying infrastructure apps (wave 8 — harbor, harbor backup, actions runners)..."
kubectl apply -f infrastructure/harbor/argocd-app-harbor.yaml
kubectl apply -f infrastructure/harbor/argocd-app-harbor-backup.yaml
kubectl delete validatingwebhookconfiguration infisical-ingress-nginx-admission 2>/dev/null; true
kubectl apply -f infrastructure/kong/ingress-kong-admin.yaml
kubectl apply -f infrastructure/actions-runner/argocd-app-actions-runner-controller.yaml
kubectl apply -f infrastructure/actions-runner/argocd-app-actions-runner-apps.yaml
kubectl apply -f infrastructure/actions-runner/argocd-app-runners-k8s-apps.yaml
kubectl apply -f infrastructure/actions-runner/argocd-app-runners-yana-ecommerce.yaml
kubectl apply -f infrastructure/actions-runner/argocd-app-runners-yana-stocks.yaml
kubectl apply -f infrastructure/actions-runner/argocd-app-runners-shared-services.yaml
kubectl apply -f infrastructure/actions-runner/argocd-app-runners-ml.yaml

echo "Applying apps (wave 9 — foundational apps)..."
kubectl apply -f apps/vaultwarden/argocd-app-vaultwarden.yaml
kubectl apply -f apps/kafka/argocd-app-strimzi.yaml

echo "Applying apps (wave 9+ — all other apps)..."
kubectl apply -f apps/kafka/argocd-app-kafka.yaml
kubectl apply -f apps/kafka-ui/argocd-app-kafka-ui.yaml
kubectl apply -f apps/uptime-kuma/argocd-app-uptime-kuma.yaml
kubectl apply -f apps/pgadmin/argocd-app-pgadmin.yaml
kubectl apply -f apps/nextcloud/argocd-app-nextcloud.yaml
kubectl apply -f apps/gotify/argocd-app-gotify.yaml
kubectl apply -f apps/apicurio/argocd-app-apicurio.yaml
# kubernetes-dashboard excluded — chart repo moved, fix URL before re-enabling (see root kustomization.yaml)
kubectl apply -f apps/yana-stocks/argocd-app-yana-stocks.yaml
kubectl apply -f apps/akan/argocd-app-akan.yaml
kubectl apply -f apps/shared-services/argocd-app-shared-services.yaml
kubectl apply -f apps/ml/argocd-app-ml.yaml
kubectl apply -f apps/dove-house-tt/argocd-app-dove-house-tt.yaml
kubectl apply -f apps/dove-house-tt-stg/argocd-app-dove-house-tt-stg.yaml

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
echo "POST-INSTALL MANUAL STEPS (see comments at top of this file for details):"
echo "  1. Patch ArgoCD dex secret"
echo "  2. Patch infisical ingress to use nginx ingressClassName"
echo "  3. Set infisical webhook failurePolicy to Ignore"
echo "  4. Headlamp SA token: kubectl create token headlamp -n headlamp --duration=8760h"
echo "  5. Set up Immich admin account at https://photos.yanatech.co.uk"
echo "  6. Configure Immich/RedisInsight/Mongo Express Authentik outposts"
echo "============================================================"
