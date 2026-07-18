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
# Every value is written through `printf '%q'`, not plain interpolation --
# a secret value containing a space, `$`, backtick, or quote will otherwise
# get silently word-split or expanded when bootstrap.sh later `source`s this
# file, truncating or corrupting it with no error at all. Confirmed this
# actually happens (2026-07-18, caught during a deliberate stress test with
# a value containing `$` and a backtick) before switching to %q.
#
# Requires: ssh access to kc1, and jq installed there (already present as of
# 2026-07-18).
set -e

OUT="$HOME/vault/vaultwarden-creds-DELETE-ME.txt"
mkdir -p "$(dirname "$OUT")"

ssh kc1 '
get() { kubectl get secret "$1" -n "$2" -o jsonpath="{.data.$3}" | base64 -d; }

v=$(get csi-rbd-secret ceph-csi-rbd userKey); printf "export CEPH_CSI_USER_KEY=%q\n" "$v"
v=$(get cloudflare-api-token cert-manager api-token); printf "export CLOUDFLARE_API_TOKEN=%q\n" "$v"
v=$(get grafana-authentik-secret monitoring client_id); printf "export GRAFANA_AUTHENTIK_CLIENT_ID=%q\n" "$v"
v=$(get grafana-authentik-secret monitoring client_secret); printf "export GRAFANA_AUTHENTIK_CLIENT_SECRET=%q\n" "$v"
v=$(get authentik-secret authentik AUTHENTIK_SECRET_KEY); printf "export AUTHENTIK_SECRET_KEY=%q\n" "$v"
v=$(get authentik-secret authentik AUTHENTIK_POSTGRESQL__HOST); printf "export AUTHENTIK_POSTGRESQL__HOST=%q\n" "$v"
v=$(get authentik-secret authentik AUTHENTIK_POSTGRESQL__NAME); printf "export AUTHENTIK_POSTGRESQL__NAME=%q\n" "$v"
v=$(get authentik-secret authentik AUTHENTIK_POSTGRESQL__USER); printf "export AUTHENTIK_POSTGRESQL__USER=%q\n" "$v"
v=$(get authentik-secret authentik AUTHENTIK_POSTGRESQL__PASSWORD); printf "export AUTHENTIK_POSTGRESQL__PASSWORD=%q\n" "$v"
v=$(get authentik-secret authentik AUTHENTIK_REDIS__HOST); printf "export AUTHENTIK_REDIS__HOST=%q\n" "$v"
v=$(get authentik-secret authentik AUTHENTIK_EMAIL__PASSWORD); printf "export AUTHENTIK_EMAIL__PASSWORD=%q\n" "$v"
v=$(get infisical-eso-credentials external-secrets clientSecret); printf "export ESO_CLIENT_SECRET=%q\n" "$v"
v=$(kubectl get secret argocd-secret -n argocd -o jsonpath="{.data.dex\.authentik\.clientSecret}" | base64 -d); printf "export ARGOCD_DEX_CLIENT_SECRET=%q\n" "$v"
v=$(get repo-akan argocd username); printf "export GIT_PAT_USERNAME=%q\n" "$v"
v=$(get repo-akan argocd password); printf "export REPO_AKAN_PAT=%q\n" "$v"
v=$(get repo-shared-services argocd password); printf "export REPO_SHARED_SERVICES_PAT=%q\n" "$v"
v=$(get repo-ml argocd password); printf "export REPO_ML_PAT=%q\n" "$v"
v=$(get repo-dove-house-tt argocd password); printf "export REPO_DOVE_HOUSE_TT_PAT=%q\n" "$v"
dockerconfig=$(kubectl get secret ghcr-secret -n dove-house-tt -o jsonpath="{.data.\.dockerconfigjson}" | base64 -d)
v=$(echo "$dockerconfig" | jq -r ".auths[\"ghcr.io\"].username"); printf "export GHCR_USERNAME=%q\n" "$v"
v=$(echo "$dockerconfig" | jq -r ".auths[\"ghcr.io\"].password"); printf "export GHCR_PAT=%q\n" "$v"
' > "$OUT"

echo "Written to $OUT"
echo "Review with: less $OUT"
echo "Copy its contents into the Vaultwarden Note, then: rm $OUT"
