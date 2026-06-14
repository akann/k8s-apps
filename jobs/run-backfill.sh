#!/usr/bin/env bash
# Run the price history backfill job on the cluster.
# Usage: ./jobs/run-backfill.sh
# Re-running is safe — the script deletes any existing job first.
set -euo pipefail

NAMESPACE=yana-stocks
JOB=price-backfill
MANIFEST="$(cd "$(dirname "$0")" && pwd)/price-backfill.yaml"
TIMEOUT=300

# ── 1. Delete previous run if it exists ──────────────────────────────────────
if kubectl get job "$JOB" -n "$NAMESPACE" &>/dev/null; then
  echo "Removing previous job..."
  kubectl delete job "$JOB" -n "$NAMESPACE" --wait=true
fi

# ── 2. Apply manifest ─────────────────────────────────────────────────────────
echo "Applying $MANIFEST ..."
kubectl apply -f "$MANIFEST"

# ── 3. Wait for pod to be created ─────────────────────────────────────────────
echo "Waiting for pod to start (up to ${TIMEOUT}s)..."
DEADLINE=$(( $(date +%s) + TIMEOUT ))
while true; do
  POD=$(kubectl get pod -n "$NAMESPACE" -l job-name="$JOB" \
        --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)
  [[ -n "$POD" ]] && break
  [[ $(date +%s) -ge $DEADLINE ]] && { echo "Timed out waiting for pod"; exit 1; }
  sleep 2
done
echo "Pod: $POD"

# ── 4. Wait for pod to be running/completed before streaming logs ─────────────
kubectl wait pod "$POD" -n "$NAMESPACE" \
  --for=condition=Ready \
  --timeout=120s 2>/dev/null \
  || kubectl wait pod "$POD" -n "$NAMESPACE" \
       --for=jsonpath='{.status.phase}'=Succeeded \
       --timeout=120s 2>/dev/null \
  || true   # pod may jump straight to Completed — that's fine

echo ""
echo "──────────────── Backfill logs ────────────────"
kubectl logs -n "$NAMESPACE" "$POD" --follow 2>/dev/null \
  || kubectl logs -n "$NAMESPACE" "$POD"
echo "────────────────────────────────────────────────"
echo ""

# ── 5. Report outcome ─────────────────────────────────────────────────────────
if kubectl wait job "$JOB" -n "$NAMESPACE" \
     --for=condition=complete --timeout=10s &>/dev/null; then
  echo "✓ Backfill completed successfully"
else
  echo "✗ Backfill failed"
  echo "  Debug: kubectl describe pod -n $NAMESPACE $POD"
  exit 1
fi
