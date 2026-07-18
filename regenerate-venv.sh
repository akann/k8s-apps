#!/bin/bash
# Regenerates the ./venv credentials file bootstrap.sh sources, by pulling
# every current value straight off the live cluster via SSH to kc1.
#
# Use this whenever the Vaultwarden Note backing ./venv needs refreshing
# (first time setup, a rotated credential, or just periodic verification
# that the Note is still accurate). See docs/disaster-recovery-runbook.md
# for the full workflow.
#
# Usage:
#   ./regenerate-venv.sh
#
# Output goes to ~/vault/vaultwarden-creds-DELETE-ME.txt (NOT into this repo
# -- never let cluster credentials land anywhere git might pick them up).
# Review it, copy its contents into the Vaultwarden Note, then delete it:
#   rm ~/vault/vaultwarden-creds-DELETE-ME.txt
#
# Requires: ssh access to kc1, and jq installed there (already present as of
# 2026-07-18).
set -e

OUT="$HOME/vault/vaultwarden-creds-DELETE-ME.txt"
mkdir -p "$(dirname "$OUT")"

ssh kc1 '
echo "export CEPH_CSI_USER_KEY=$(kubectl get secret csi-rbd-secret -n ceph-csi-rbd -o jsonpath="{.data.userKey}" | base64 -d)"
echo "export CLOUDFLARE_API_TOKEN=$(kubectl get secret cloudflare-api-token -n cert-manager -o jsonpath="{.data.api-token}" | base64 -d)"
echo "export GRAFANA_AUTHENTIK_CLIENT_ID=$(kubectl get secret grafana-authentik-secret -n monitoring -o jsonpath="{.data.client_id}" | base64 -d)"
echo "export GRAFANA_AUTHENTIK_CLIENT_SECRET=$(kubectl get secret grafana-authentik-secret -n monitoring -o jsonpath="{.data.client_secret}" | base64 -d)"
echo "export AUTHENTIK_SECRET_KEY=$(kubectl get secret authentik-secret -n authentik -o jsonpath="{.data.AUTHENTIK_SECRET_KEY}" | base64 -d)"
echo "export AUTHENTIK_POSTGRESQL__HOST=$(kubectl get secret authentik-secret -n authentik -o jsonpath="{.data.AUTHENTIK_POSTGRESQL__HOST}" | base64 -d)"
echo "export AUTHENTIK_POSTGRESQL__NAME=$(kubectl get secret authentik-secret -n authentik -o jsonpath="{.data.AUTHENTIK_POSTGRESQL__NAME}" | base64 -d)"
echo "export AUTHENTIK_POSTGRESQL__USER=$(kubectl get secret authentik-secret -n authentik -o jsonpath="{.data.AUTHENTIK_POSTGRESQL__USER}" | base64 -d)"
echo "export AUTHENTIK_POSTGRESQL__PASSWORD=$(kubectl get secret authentik-secret -n authentik -o jsonpath="{.data.AUTHENTIK_POSTGRESQL__PASSWORD}" | base64 -d)"
echo "export AUTHENTIK_REDIS__HOST=$(kubectl get secret authentik-secret -n authentik -o jsonpath="{.data.AUTHENTIK_REDIS__HOST}" | base64 -d)"
echo "export AUTHENTIK_EMAIL__PASSWORD=$(kubectl get secret authentik-secret -n authentik -o jsonpath="{.data.AUTHENTIK_EMAIL__PASSWORD}" | base64 -d)"
echo "export ESO_CLIENT_SECRET=$(kubectl get secret infisical-eso-credentials -n external-secrets -o jsonpath="{.data.clientSecret}" | base64 -d)"
echo "export ARGOCD_DEX_CLIENT_SECRET=$(kubectl get secret argocd-secret -n argocd -o jsonpath="{.data.dex\.authentik\.clientSecret}" | base64 -d)"
echo "export GIT_PAT_USERNAME=$(kubectl get secret repo-akan -n argocd -o jsonpath="{.data.username}" | base64 -d)"
echo "export REPO_AKAN_PAT=$(kubectl get secret repo-akan -n argocd -o jsonpath="{.data.password}" | base64 -d)"
echo "export REPO_SHARED_SERVICES_PAT=$(kubectl get secret repo-shared-services -n argocd -o jsonpath="{.data.password}" | base64 -d)"
echo "export REPO_ML_PAT=$(kubectl get secret repo-ml -n argocd -o jsonpath="{.data.password}" | base64 -d)"
echo "export REPO_DOVE_HOUSE_TT_PAT=$(kubectl get secret repo-dove-house-tt -n argocd -o jsonpath="{.data.password}" | base64 -d)"
echo "export GHCR_USERNAME=$(kubectl get secret ghcr-secret -n dove-house-tt -o jsonpath="{.data.\.dockerconfigjson}" | base64 -d | jq -r ".auths[\"ghcr.io\"].username")"
echo "export GHCR_PAT=$(kubectl get secret ghcr-secret -n dove-house-tt -o jsonpath="{.data.\.dockerconfigjson}" | base64 -d | jq -r ".auths[\"ghcr.io\"].password")"
' > "$OUT"

echo "Written to $OUT"
echo "Review with: less $OUT"
echo "Copy its contents into the Vaultwarden Note, then: rm $OUT"
