# Cluster Updates & Incident Log

Chronological log of fixes, incidents, and resolved issues. For ongoing operational quirks that are part of the permanent setup, see the Appendix in [README.md](README.md).

---

## 2026-06-30

### kured permanently stuck on k8s-worker-2 — drainTimeout + forceReboot fix

**Symptom:** `k8s-worker-2` was cordoned by kured (`node.kubernetes.io/unschedulable: kured`) but never rebooted. kured was stuck in an infinite drain-eviction loop, retrying every 60s.

**Root cause:** All CNPG clusters had `instances: 1`. A single-instance CNPG cluster creates two PDBs:
- `<name>` — allows 0 disruptions on the replica set (empty, no replicas)
- `<name>-primary` — `minAvailable: 1` on the primary, meaning `ALLOWED DISRUPTIONS: 0`

kured's drain cannot evict the primary pod; the node never drains, so reboot never happens, so the node stays cordoned.

**Fix — two parts:**
1. Scale all CNPG clusters to ≥ 2 instances so the primary can failover during drain:
   - `auth-service-pg`: 1 → 2 instances (`apps/yana-stocks/auth-service/cnpg-cluster.yaml`)
   - `immich-postgres`: 1 → 2 instances (`apps/immich/postgres-cluster.yaml`)
   - `pg-main`: 3 → 4 instances (`infrastructure/cnpg-clusters/pg-main.yaml`)
2. Add drain timeout + force-reboot to kured so primary nodes get rebooted even if drain times out (CNPG recovers via WAL replay):
   - `infrastructure/kured/argocd-app-kured.yaml`:
     ```yaml
     drainTimeout: 5m
     forceReboot: true
     ```

---

### CNPG backups — auth-service-pg had no backup coverage

**Problem:** `auth-service-pg` had no barman configuration and no ScheduledBackup. Data loss risk: entire DB.

**Fix:**
- Added barman backup block to `apps/yana-stocks/auth-service/cnpg-cluster.yaml`:
  - WAL streaming + daily base backup → MinIO `s3://cnpg-backups/auth-service-pg/`
  - 7-day retention, gzip compression
- New `apps/yana-stocks/auth-service/external-secret-minio.yaml` — provisions `cnpg-minio-credentials` from Infisical keys `/cnpg-clusters/MINIO_ACCESS_KEY_ID` and `/cnpg-clusters/MINIO_SECRET_KEY`
- New `apps/yana-stocks/auth-service/scheduled-backup.yaml` — daily ScheduledBackup at 01:00

---

### Velero — PVC data not being backed up

**Problem:** Velero had `snapshotsEnabled: false` and no `node-agent` DaemonSet. Only Kubernetes API objects (Deployments, Services, CRDs, etc.) were backed up — no PVC contents.

**Fix:** Updated `infrastructure/velero/argocd-app-velero.yaml`:
- `deployNodeAgent: true` — enables Kopia fs-backup DaemonSet on all nodes
- `defaultVolumesToFsBackup: true` in the daily schedule template — all PVCs included by default

---

### harbor-database — no backup coverage

**Problem:** `harbor-database` is a plain StatefulSet (`goharbor/harbor-db`), not managed by CNPG. No backup existed.

**Fix:**
- New `infrastructure/harbor/db-backup-cronjob.yaml` — CronJob `harbor-db-backup` runs daily at 04:00:
  - initContainer: `postgres:16-alpine` pg_dumps the `registry` DB → `/backup/harbor-$(date +%A).sql.gz` (rolling 7-day filenames)
  - main container: `amazon/aws-cli` uploads to MinIO `s3://cnpg-backups/harbor-db/`
- New `infrastructure/harbor/external-secret-minio.yaml` — provisions `minio-backup-credentials` in `harbor` namespace
- New `infrastructure/harbor/argocd-app-harbor-backup.yaml` — new ArgoCD Application `harbor-backup` (wave 9) pointing to `infrastructure/harbor/`
- Added `infrastructure/harbor/argocd-app-harbor-backup.yaml` to root `kustomization.yaml`

---

### Loki chunks-cache excessive memory usage

**Problem:** Default `chunksCache.allocatedMemory: 8192` (8Gi) caused Loki to reserve 8Gi of RAM on k8s-worker-1, contributing to high memory pressure.

**Fix:** Set `chunksCache.allocatedMemory: 2048` (2Gi) in `infrastructure/loki/argocd-app-loki.yaml`. Saved ~6Gi working memory on worker-1.

---

### KEDA gRPC timeout — metrics-apiserver blocked by NetworkPolicy

**Problem:** KEDA `metrics-apiserver` could not reach the KEDA operator gRPC endpoint (port 9666) within the `keda` namespace. The `default-deny-all` NetworkPolicy blocked intra-namespace traffic not explicitly whitelisted.

**Fix:** Added intra-namespace ingress rule for port 9666 to the `allow-keda` policy in `infrastructure/network-policies/netpol-infrastructure.yaml`:
```yaml
- from:
    - podSelector: {}   # metrics-apiserver → operator gRPC
  ports:
    - port: 9666
```

---

### Empty MinIO buckets deleted

Deleted stale empty buckets `yana-stocks-datasets` and `yana-stocks-exports` from MinIO (`minio-console.yanatech.co.uk`). These were never populated; no data lost.

---

### yana-stocks OutOfSync — KEDA replica drift on portfolio-api, portfolio-service, profile-service

**Symptom:** `yana-stocks` app showing OutOfSync for three deployments — live `replicas: 2`, git `replicas: 1`.

**Root cause:** KEDA ScaledObjects scale these deployments at runtime. ArgoCD sees the live replica count diverge from the manifest's static value and flags it as OutOfSync. Same cosmetic issue as `price-ingestor`, `price-processor`, `sentiment-analyzer` (already fixed).

**Fix:** Added `/spec/replicas` to `ignoreDifferences` for all three in `apps/yana-stocks/argocd-app-yana-stocks.yaml`.

---

## 2026-06-29

### KEDA Kafka ScaledObjects added to remaining yana-stocks consumers

**Change:** Added `keda-scaledobject.yaml` to `price-processor`, `profile-service`, `portfolio-service`, and `portfolio-api`. All use lag threshold 100 on their respective topics, matching the existing `sentiment-analyzer` pattern.

| Service | min | max | Topic(s) |
|---|---|---|---|
| price-processor | 0 | 3 | `stocks.prices.raw` |
| profile-service | 1 | 3 | `users.registered` |
| portfolio-service | 1 | 3 | `stocks.prices.processed`, `users.registered` |
| portfolio-api | 1 | 3 | `stocks.prices.processed`, `stocks.signals.sentiment`, `stocks.signals.prediction` |

`price-processor` scales to 0 (pure pipeline, no user-facing cold start). `profile-service` keeps min 1 because profile creation must be near-immediate post-registration. `portfolio-service` and `portfolio-api` keep min 1 because they serve HTTP traffic.

---

## 2026-06-24

### Kong `RepeatedResourceWarning` — 12 duplicate CRDs (resolved)

**Symptom:** ArgoCD reported `RepeatedResourceWarning` for 12 Kong CRDs — each one "appeared 2 times among application resources".

**Root cause:** The `ingress` chart v0.24.0 embeds the `kong` sub-chart **twice** via Helm dependency aliases (`controller` and `gateway`). Each alias has its own `crds/` directory, which ArgoCD includes via `--include-crds`. Additionally, ArgoCD renders against the live cluster, so the sub-chart template's `lookup()` detects existing CRDs and also renders them from `templates/custom-resource-definitions.yaml` — producing two copies per CRD.

**Fix:** Set `ingressController.installCRDs: false` on both aliases in `infrastructure/kong/argocd-app-kong.yaml`. This forces the template to take the explicit-value path and skip CRD rendering, leaving `crds/` as the sole managed source.

```yaml
# infrastructure/kong/argocd-app-kong.yaml
gateway:
  ingressController:
    installCRDs: false
controller:
  ingressController:
    installCRDs: false
```

---

### Kured drain blocked by CNPG PDB (k8s-worker-1 reboot)

**Symptom:** kured cordoned `k8s-worker-1` after a kernel update but was stuck in an eviction loop for 6+ hours. Two CNPG primary pods were on the node: `pg-main-4` (`cnpg-clusters`) and `immich-postgres-1` (`immich`). Both had `disruptionsAllowed: 0` on their PDBs.

**Root cause:** `kubectl drain` uses the eviction API, which **respects PodDisruptionBudgets**. CNPG sets `minAvailable: 1` on primary pods, so `disruptionsAllowed` is always 0 while only one primary exists.

**Fix:** Delete the primary pods directly — `kubectl delete pod` bypasses PDB (delete API vs eviction API). CNPG immediately promotes the most-up-to-date standby on another node.

```bash
# Identify CNPG pods on the cordoned node
kubectl get pods -A -o wide --field-selector spec.nodeName=<node>

# Direct delete bypasses PDB — CNPG auto-promotes standby
kubectl delete pod <pg-main-N> -n cnpg-clusters
kubectl delete pod <immich-postgres-N> -n immich

# kured proceeds with drain and reboot automatically
# After reboot, deleted pods are recreated as standby replicas
```

---

### CNPG standby stuck in WAL replay — timeline mismatch (pg-main-2)

**Symptom:** `pg-main-2` was 0/1 Running for 8+ hours with 8+ restarts. Logs showed a loop:
```
"waiting for WAL to become available at 13/9E11F740"
"Refusing to restore future timeline history file" fileTimeline:15 clusterTimeline:14
```

**Root cause:** The pod's PVC held stale data from a timeline the cluster had already advanced past (multiple primary failovers during the kured incident bumped the timeline to 15; the PVC was stuck on 14). Deleting just the pod did **not** fix this — CNPG reattached the same PVC and the instance resumed from the same stuck position.

**Fix:** Delete both the pod and its PVC. CNPG provisions a new PVC, creates a join pod that runs `pg_basebackup` from the primary (~30–60 s), then starts the new standby on the correct timeline.

```bash
kubectl delete pod pg-main-2 -n cnpg-clusters --wait=true
kubectl delete pvc pg-main-2 -n cnpg-clusters

# CNPG creates pg-main-5-join-xxxxx → pg-main-5 (1/1 Running)
# Cluster returns to: Cluster in healthy state 3/3
```

**Note:** CNPG increments instance numbers monotonically and never reuses them. After this incident the pg-main instances are `pg-main-1` (primary, kw2), `pg-main-4` (standby, kw2), `pg-main-5` (standby, kw1).

---

### kube-scheduler and kube-controller-manager on cp-2/cp-3 pointing to wrong API server (resolved)

**Symptom:** `kube-scheduler-k8s-cp-2` and `kube-scheduler-k8s-cp-3` were `0/1 Running` (37 and 0 restarts over 12h respectively). `kube-controller-manager-k8s-cp-2/3` were `1/1 Running` but completely non-functional. All four components logged the same error:

```
dial tcp 192.168.22.22:6443: i/o timeout    # cp-2
dial tcp 192.168.22.23:6443: i/o timeout    # cp-3
```

**Root cause:** `/etc/kubernetes/scheduler.conf` and `/etc/kubernetes/controller-manager.conf` on both cp-2 and cp-3 had `server: https://192.168.22.2x:6443` — the Proxmox management network IPs (vmbr0, VLAN 22), not the Kubernetes network IPs (vmbr1, VLAN 33). The cluster's Kubernetes workloads live entirely on `192.168.33.x`; the management IPs are unreachable from within the cluster. The misconfiguration was present since the control plane nodes joined (likely kubeadm picked up the primary NIC which was the management interface). `kubelet.conf` and `admin.conf` on the same nodes correctly pointed to `192.168.33.21:6443` and were unaffected.

The cluster appeared healthy because cp-1's scheduler and controller-manager (both correctly configured) won leader election and handled all scheduling/control work. The other two replicas were silently dead, leaving the cluster with no HA on scheduler or controller-manager.

**Fix:**

```bash
# On k8s-cp-2
sudo sed -i 's|server: https://192.168.22.22:6443|server: https://192.168.33.21:6443|g' \
  /etc/kubernetes/scheduler.conf /etc/kubernetes/controller-manager.conf

# On k8s-cp-3
sudo sed -i 's|server: https://192.168.22.23:6443|server: https://192.168.33.21:6443|g' \
  /etc/kubernetes/scheduler.conf /etc/kubernetes/controller-manager.conf

# Restart static pods by briefly moving manifests out then back (kubectl delete pod is a no-op for
# static pods — kubelet recreates the mirror pod without restarting the container)
sudo mv /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/ && sleep 5 && \
  sudo mv /tmp/kube-scheduler.yaml /etc/kubernetes/manifests/
sudo mv /etc/kubernetes/manifests/kube-controller-manager.yaml /tmp/ && sleep 5 && \
  sudo mv /tmp/kube-controller-manager.yaml /etc/kubernetes/manifests/
```

Result: all 6 control plane components `1/1 Running`, clean leader election logs, full HA restored.

---

### alertmanager-gotify-bridge 401 Unauthorized (resolved)

**Symptom:** `alertmanager-gotify-bridge` was `1/1 Running` but flooding logs with:
```
Non-200 response from gotify at http://gotify.gotify.svc.cluster.local/message. Code: 401, Status: 401 Unauthorized
```

**Root cause:** The token stored in Infisical at `/gotify/ALERTMANAGER_TOKEN` (`AvMQK99JPxH2tYh`) did not match any active application token in Gotify. The Gotify "Alert Manager" app (id:3) had been recreated/regenerated at some point with a new token (`A7bvx9Aev_TS8GJ`), but Infisical was never updated. ESO was faithfully syncing the stale token into `gotify-secret`. This was masked for 18+ days by a concurrent NetworkPolicy bug (i/o timeout) that was fixed first.

**Token discovery:**
```bash
ADMIN_PASS=$(kubectl get secret gotify-secret -n gotify -o jsonpath='{.data.admin-password}' | base64 -d)
curl -s -u "admin:$ADMIN_PASS" https://gotify.yanatech.co.uk/application
# Returns all apps with their valid tokens
```

**Fix:**
1. Patched `gotify-secret` directly with the correct token
2. Restarted the bridge deployment
3. **Updated Infisical `/gotify/ALERTMANAGER_TOKEN`** with `A7bvx9Aev_TS8GJ` (required — ESO refreshes every 1h and would overwrite the patch otherwise)

```bash
kubectl patch secret gotify-secret -n gotify --type='json' \
  -p='[{"op":"replace","path":"/data/alertmanager-token","value":"<base64-of-token>"}]'
kubectl rollout restart deployment alertmanager-gotify-bridge -n gotify
```

Result: bridge starts cleanly, no 401 errors, no i/o timeouts.

---

## 2026-06-28/29

### Harbor Degraded — RWO PVC rolling update deadlock (resolved)

**Symptom:** Harbor showed `Degraded` in ArgoCD for 94+ minutes. `harbor-jobservice` and `harbor-registry` had new RS pods stuck in `ContainerCreating` with no events (events expire after ~1h). kubelet on k8s-worker-2 logged:
```
unmounted volumes=[job-logs], unattached volumes=[job-logs], failed to process volumes=[]: context deadline exceeded
```

**Root cause:** Two compounding issues:
1. `targetRevision: "*"` in `argocd-app-harbor.yaml` caused an uncontrolled chart upgrade when a new Harbor chart version was published.
2. The upgrade triggered a rolling update. The new pods were scheduled on `k8s-worker-2`; the old pods (with RWO Ceph RBD PVCs) were on `k8s-worker-1`. Kubernetes deadlock: new pods can't mount the volume (held by old pods on another node), old pods won't terminate (rolling update waits for new pods to be Ready first).

**Why kubectl rollout undo failed:** ArgoCD's `selfHeal: true` immediately re-applied the git state, overwriting the rollback within seconds.

**Fix:**
1. Patched `harbor-jobservice` and `harbor-registry` Deployments directly to `Recreate` strategy, breaking the deadlock:
```bash
kubectl patch deployment harbor-jobservice -n harbor \
  -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'
kubectl patch deployment harbor-registry -n harbor \
  -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'
```
All pods Running within 1 minute.

2. Updated git:
   - `targetRevision: "*"` → `targetRevision: "1.19.1"` (pin chart version)
   - Added top-level `updateStrategy: {type: Recreate}` to Helm values (Harbor chart uses `.Values.updateStrategy.type`, not per-component keys)

**Key lesson:** Harbor's jobservice and registry use RWO PVCs. `updateStrategy: Recreate` must be set at the **top level** of Harbor Helm values — not under `jobservice:` or `registry:` (those keys are silently ignored by the chart template).

```yaml
# argocd-app-harbor.yaml (correct location)
helm:
  valuesObject:
    updateStrategy:
      type: Recreate
```

---

### Gotify Authentik forward auth — attempted, reverted

**Context:** Added Authentik forward auth to Gotify to avoid exposing it with only its own login. Configured an Authentik provider, application, and outpost via the Authentik UI, then added auth annotations and an outpost ingress to `gotify.yaml`.

**Problem:** Authentik forward auth and application-level auth are orthogonal concerns. Authentik acts as an access gate (decides who can reach the URL). Once through, Gotify still presents its own login screen. Gotify is a React SPA using `localStorage` tokens — nginx/Authentik cannot inject credentials or bypass the app's internal auth flow. The result was two sequential login screens, which is worse UX than no Authentik at all.

**Revert:** Removed auth annotations and outpost ingress from `gotify.yaml`, removed `ak-outpost-svc.yaml` (ExternalName service). The `/message` and `/stream` bypass ingress (`gotify-api`) was retained for the alertmanager bridge.

**Conclusion:** Forward auth is only appropriate for apps that either (a) have no auth of their own, or (b) support header-based SSO injection. Gotify's SPA architecture makes it incompatible with forward auth as an SSO replacement.

---

### Alertmanager email notifications removed

**Change:** Removed all email routing from Alertmanager. Previously `critical-alerts` receiver sent to both Gotify and SMTP2GO; now all alerts route to Gotify only.

Removed from `argocd-app-monitoring.yaml`:
- `global.smtp_*` settings
- `email_configs` from `critical-alerts` receiver
- `grafana-smtp-secret` volume + volume mount from `alertmanagerSpec`

The `external-secret-smtp.yaml` and `grafana-smtp-secret` secret still exist but are no longer referenced by Alertmanager. The `grafana-smtp-secret` ESO resource can be deleted if Grafana SMTP is also not needed.

---

### ArgoCD app health alerts → Gotify via Prometheus

**Problem:** No visibility into ArgoCD app health changes (Degraded, Missing, OutOfSync) — discovered Harbor was Degraded only by chance.

**Fix:**

1. **ArgoCD controller metrics** — enabled via `infrastructure/argocd/values.yaml`:
```yaml
controller:
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
      additionalLabels:
        release: kube-prometheus-stack
```
This creates a `Service` on port 8082 and a `ServiceMonitor` so Prometheus scrapes `argocd_app_info` from the ArgoCD application controller.

2. **PrometheusRule** — `infrastructure/monitoring/rules/prometheusrule-argocd.yaml`:
   - `ArgoCDAppDegraded` (critical, 5m) — fires when `health_status="Degraded"`
   - `ArgoCDAppMissing` (critical, 5m) — fires when `health_status="Missing"`
   - `ArgoCDAppOutOfSync` (warning, 15m) — fires when `sync_status="OutOfSync"`

3. **Alertmanager routing** — critical alerts → Gotify (already configured). The PrometheusRule labels `severity: critical` for Degraded/Missing, so they route to the `critical-alerts` receiver → Gotify bridge.
