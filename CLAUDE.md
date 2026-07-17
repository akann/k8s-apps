# k8s-apps — Claude Code Instructions

## Overview

GitOps repository for Akan's homelab Kubernetes cluster. All infrastructure and applications are defined here and deployed via ArgoCD. Everything must be committed to git — nothing deployed manually without a follow-up commit.

**Principle:** GitOps-first. Correctness over speed. If it's not in git, it doesn't exist.

## Repository Location

- **Remote:** `github.com/akann/k8s-apps`
- **Local on cluster:** `~/repo/k8s-apps` on `k8s-cp-1` (192.168.33.21)
- **ArgoCD:** `https://argocd.yanatech.co.uk` (v3.4.2)

## Cluster

- **6-node Kubernetes** (kubeadm, v1.32): control planes k8s-cp-1/2/3 (192.168.33.21-23), workers k8s-worker-1/2/3 (192.168.33.31-33)
- **3-node Proxmox:** pve1-3 (192.168.22.11-13)
- **Domain:** `yanatech.co.uk`
- **kubectl alias on k8s-cp-1:** `argocd='argocd --grpc-web'`

## Repo Structure

```
k8s-apps/
├── bootstrap.sh                    # Ordered app deployment for fresh cluster
├── apps/                           # Application ArgoCD apps
│   ├── akan/                      # akan personal site (akan.nkweini.org, wave 9, source: akann/akan k8s/akan/)
│   ├── immich/
│   ├── kafka/
│   ├── kafka-ui/
│   ├── nextcloud/
│   ├── pgadmin/
│   ├── uptime-kuma/
│   ├── vaultwarden/
│   ├── gotify/
│   ├── apicurio/
│   ├── kubernetes-dashboard/
│   ├── yana-stocks/               # yana-stocks microservices
│   ├── shared-services/           # shared-services apps (email-api, email-service, source: akann/shared-services k8s/)
│   ├── ml/                        # ml repo apps (k8s-docs RAG chatbot, source: akann/ml k8s/, directory.recurse: true)
│   └── dove-house-tt/             # Dove House TT members app (dovehousett.org, wave 9, source: akann/dove-house-tt k8s/dove-house-tt/)
└── infrastructure/
    ├── argocd/
    ├── authentik/
    ├── ceph-csi/
    ├── cert-manager/
    ├── cilium/                     # CiliumNetworkPolicies
    ├── cnpg/                       # CloudNativePG operator
    ├── cnpg-clusters/              # pg-main cluster
    ├── descheduler/
    ├── eso/                        # External Secrets Operator
    ├── goldilocks/
    ├── harbor/
    ├── headlamp/
    ├── infisical/
    ├── ingress-nginx/
    ├── kafka/                      # Strimzi + Kafka cluster + topics
    ├── keda/
    ├── kong/                       # Kong API Gateway
    ├── kured/
    ├── loki/
    ├── metallb/
    ├── minio/                      # MinIO object storage
    ├── mongodb/                    # MongoDB replicaset
    ├── mongo-express/              # MongoDB UI
    ├── monitoring/                 # kube-prometheus-stack
    ├── network-policies/           # NetworkPolicies for all namespaces
    ├── redis/                      # Redis standalone
    ├── redis-insight/              # Redis UI
    ├── reflector/
    ├── reloader/
    ├── tempo/
    └── velero/
```

## Core Infrastructure

### Networking

- **CNI:** Cilium (native routing mode — no encapsulation)
- **Load Balancer:** MetalLB, pool `192.168.33.200-249`
  - `192.168.33.200` — ingress-nginx
  - `192.168.33.201` — infisical bundled nginx (scaled to 0, do not use)
  - `192.168.33.202` — Kong API Gateway
- **Ingress:** ingress-nginx at `192.168.33.200`
  - `externalTrafficPolicy: Local` + `use-forwarded-headers` with `forwarded-for-header: CF-Connecting-IP` and `proxy-real-ip-cidr` = Cloudflare ranges → access logs show the real visitor IP for Cloudflare-proxied hosts (LAN visitors bypass Cloudflare via split-horizon DNS and log their LAN IP directly). Don't revert to `Cluster` — kube SNAT rewrites sources to node IPs and breaks the Cloudflare trust check.
  - Access logs are JSON (`log-format-upstream` + `log-format-escape-json`, includes `$host` which the default format lacks) → queryable in Loki with `| json | host="..."`. The "Ingress Access Logs" Grafana dashboard (`infrastructure/monitoring/dashboards/cm-ingress-access-logs.yaml`, per-host template variable) is built on this — don't remove the JSON format without reworking it. Promtail's custom `scrapeConfigs` must keep its inline `pipeline_stages: [cri: {}]` — overriding `scrapeConfigs` discards the chart-default pipeline, and without the cri stage log lines keep their `<ts> stdout F` prefix in Loki, silently breaking `| json` everywhere.
- **TLS:** cert-manager, Let's Encrypt wildcards via Cloudflare DNS-01, reflected to all namespaces via Reflector:
  - `wildcard-yanatech-tls` (`*.yanatech.co.uk`) — Cloudflare token from Infisical `/cert-manager/api-token`
  - `wildcard-nkweini-tls` (`*.nkweini.org`) — Cloudflare token from Infisical `/cert-manager/api-token-nkweini` (separate ExternalSecret `cloudflare-api-token-nkweini` scoped to nkweini.org zone)
  - `wildcard-dovehousett-tls` (`*.dovehousett.org` + apex) — Cloudflare token from Infisical `/cert-manager/api-token-dovehousett` (ExternalSecret `cloudflare-api-token-dovehousett` scoped to dovehousett.org zone)

### Storage

- **Ceph RBD** (`ceph-rbd` StorageClass) — default StorageClass
- **Ceph cluster:** 8.4TiB raw, 6 OSDs, monitors at 192.168.22.11-13:6789
- **Cluster ID:** `&lt;see Vaultwarden&gt;`
- **CRITICAL:** Ceph CSI egress to OSD ports (6802-6809) requires `CiliumNetworkPolicy` with `toCIDR` — standard `NetworkPolicy` does NOT work in Cilium native routing mode. See `infrastructure/cilium/ciliumnetpol-ceph-osd.yaml`

### Secrets

- **ESO:** External Secrets Operator syncs from Infisical
  - Webhook disabled (`webhook.create: false`, `certController.create: false`) — Cilium native routing blocks kube-apiserver node IP connections to in-cluster services
  - ClusterSecretStore: `infisical` (Infisical provider — main store for all app secrets)
  - ClusterSecretStore: `k8s-yana-stocks` (Kubernetes provider — syncs `auth-service-pg-app` secret from yana-stocks namespace into monitoring namespace for the Grafana PostgreSQL datasource). Auth via `eso-pg-reader` ServiceAccount in monitoring.
  - Project: `k8s-homelab` (ID `&lt;see Vaultwarden&gt;`)
  - Environment: `prod`
- **ExternalSecret format:**

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: my-secret
  namespace: my-namespace
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: infisical
    kind: ClusterSecretStore
  target:
    name: my-secret
    creationPolicy: Owner
  data:
    - secretKey: my-key
      remoteRef:
        key: /my-folder/MY_SECRET_NAME
```

- **Vaultwarden:** `vault.yanatech.co.uk` — bootstrap source of truth for manual secrets

### Databases

- **CNPG pg-main:** `pg-main-rw.cnpg-clusters.svc.cluster.local:5432` — shared cluster for vaultwarden, authentik, nextcloud, infisical, apicurio (4 instances; barman backup to MinIO `s3://cnpg-backups/pg-main/`)
- **Immich postgres:** `immich-postgres-rw.immich.svc.cluster.local:5432` — dedicated CNPG cluster using `ghcr.io/tensorchord/cloudnative-vectorchord:16-1.1.1` (2 instances)
- **k8s-docs postgres:** `k8s-docs-pg-rw.k8s-docs.svc.cluster.local:5432` — dedicated CNPG cluster, same `cloudnative-vectorchord` image as Immich (2 instances) but not shared with it — separate instance reserved for future ML work too
- **MongoDB:** `mongodb-headless.mongodb.svc.cluster.local:27017` (replicaSet=rs0)
- **Redis:** `redis-master.redis.svc.cluster.local:6379`
- **MinIO:** `minio.minio.svc.cluster.local:9000`

### Backup Strategy

- **CNPG clusters (pg-main, auth-service-pg, immich-postgres):** barman WAL streaming + daily ScheduledBackup → Backblaze B2 `s3://yanatech-cnpg-backups/` (same B2 account as Velero, `s3.eu-central-003.backblazeb2.com`) — provides PITR to any second. **Changed 2026-07-18** from in-cluster MinIO: MinIO's own storage sits on Ceph RBD, so a Ceph loss would previously have taken every Postgres backup down with it — the only other off-cluster target (Velero) deliberately excludes CNPG PGDATA (see below), so Postgres had no surviving backup in a full-cluster-loss scenario. Each namespace has its own `cnpg-b2-credentials` ExternalSecret (`external-secret-b2.yaml`, same pattern as the pre-existing `cnpg-minio-credentials`) pulling from Infisical `/cnpg-clusters/ACCESS_KEY_ID` + `/cnpg-clusters/ACCESS_SECRET_KEY` — **these Infisical keys and the `yanatech-cnpg-backups` B2 bucket/application key need to exist for this to actually sync**; the ExternalSecret CRD predates this change (from an earlier bulk-scaffolding commit) but was unverified against real Infisical values. `k8s-docs-pg` (ml repo) and `dove-house-tt-pg` (dove-house-tt repo) are not covered by this change yet — same MinIO-destination pattern, follow-up in their own repos.
- **harbor-database** (plain StatefulSet, not CNPG): daily pg_dump CronJob (`harbor-db-backup` in `harbor` ns) → MinIO `s3://cnpg-backups/harbor-db/`, rolling 7-day filenames (`harbor-Monday.sql.gz` … `harbor-Sunday.sql.gz`)
- **PVC data (non-CNPG workloads):** Velero node-agent (Kopia fs-backup) on all nodes, weekly schedule (`velero-weekly-backup`, cron `0 2 * * 0`) → Backblaze B2 `s3://yanatech-velero/`. **Opt-in as of 2026-07-16** (`defaultVolumesToFsBackup: false` in `infrastructure/velero/argocd-app-velero.yaml`) — each real PVC-mounting workload carries an explicit `backup.velero.io/backup-volumes: <volname>` pod annotation (gotify, uptime-kuma, vaultwarden set directly on the Deployment; harbor/infisical-redis/minio/mongodb/monitoring(prometheus+alertmanager)/loki/tempo/nextcloud/pgadmin/redis set via the chart's `podAnnotations`/`podMetadata` Helm value; kafka's `KafkaNodePool.spec.template.pod.metadata.annotations`).
  - **Root cause of the prior `PartiallyFailed` runs (fixed 2026-07-16):** the old opt-out mode (`defaultVolumesToFsBackup: true`) tried to fs-backup *every* volume on *every* pod cluster-wide, including Velero's own short-lived `<namespace>-default-kopia-maintain-job-*` repository-maintenance Job pods (created internally by Velero itself, not editable via this repo) and other pods' scratch/tmp emptyDirs (argocd-repo-server, argocd-applicationset-controller, kong-controller). Most showed up as harmless "Skip pod volume" warnings (126 of 132 warnings in the last run), but ~5-7 were genuine errors — a race where the ephemeral pod's volume was torn down before Velero's node-agent could expose it ("context deadline exceeded" / "etcd timed out" / volume path not found). Switching to opt-in stops Velero from touching any of these ephemeral pods at all.
  - **CNPG Postgres clusters (`pg-main`, `auth-service-pg`, `k8s-docs-pg`, `dove-house-tt-pg`, `dove-house-tt-stg-pg`, `ops-agent-pg`) are deliberately excluded** from Velero fs-backup as part of this fix — no `backup.velero.io/backup-volumes` annotation is set on them. They were being swept up under the old opt-out mode, but a live Kopia fs-backup of a running PGDATA directory with no `pg_backup_start`/`stop` bracketing has no consistency guarantee (unlike a real snapshot) and was never reliable protection; barman WAL-streaming (below) already gives clean PITR to any second for all of these, so fs-backup was pure redundant risk, not redundant safety.
- **MinIO credentials for backup jobs:** Infisical keys `/cnpg-clusters/MINIO_ACCESS_KEY_ID` + `/cnpg-clusters/MINIO_SECRET_KEY`, provisioned via ExternalSecret in each namespace

### kured (node reboot daemon)

- **Config:** `infrastructure/kured/argocd-app-kured.yaml`
- **drainTimeout: 5m** — drain attempt times out after 5 minutes rather than waiting forever
- **forceReboot: true** — reboots the node even if drain didn't fully complete (CNPG primary recovers via WAL replay after reboot)
- **IMPORTANT:** CNPG clusters must have `instances ≥ 2` for kured drains to succeed. A single-instance CNPG cluster sets its primary PDB to `ALLOWED DISRUPTIONS: 0`, permanently blocking drain. If a worker self-cordon and kured is stuck, first check CNPG PDB status: `kubectl get pdb -A`

### SSO

- **Authentik:** `https://authentik.yanatech.co.uk` — SSO for all services
- **Forward auth pattern** (for apps without native OIDC):
  1. Create Authentik provider (Proxy, Forward auth, single application)
  2. Create Authentik application → auto-deploys `ak-outpost-<name>` pod in `authentik` namespace
  3. Create ExternalName Service in app namespace pointing to outpost
  4. Create outpost Ingress routing `/outpost.goauthentik.io` on app hostname
  5. Add auth annotations to main Ingress:

```yaml
nginx.ingress.kubernetes.io/auth-url: "https://<hostname>/outpost.goauthentik.io/auth/nginx"
nginx.ingress.kubernetes.io/auth-signin: "https://<hostname>/outpost.goauthentik.io/start?rd=$escaped_request_uri"
nginx.ingress.kubernetes.io/auth-response-headers: "Set-Cookie,X-authentik-username,X-authentik-groups,X-authentik-email,X-authentik-name,X-authentik-uid"
nginx.ingress.kubernetes.io/auth-snippet: |
  proxy_set_header X-Original-URL $scheme://$http_host$request_uri;
```

- **CRITICAL:** `auth-url` must use the external hostname, NOT the internal service URL. The outpost matches by external host.
- **ingress-nginx** requires `allowSnippetAnnotations: true` AND `annotations-risk-level: Critical` for `auth-snippet`

## ArgoCD Conventions

### Application format

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "5"
spec:
  project: default
  source:
    repoURL: https://github.com/akann/k8s-apps
    path: apps/my-app
    targetRevision: HEAD
  destination:
    server: https://kubernetes.default.svc
    namespace: my-namespace
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

### Sync waves

- Wave 0: MetalLB, Ceph CSI
- Wave 1: Cilium, cert-manager, ingress-nginx
- Wave 2: MetalLB config, cert-manager config
- Wave 3: Reflector, Reloader, Kured, Descheduler, KEDA, Argo Rollouts, NetworkPolicies
- Wave 4: Authentik, Monitoring, Tempo, Velero
- Wave 5: Loki, Promtail, Headlamp, Goldilocks, Redis, MongoDB, MinIO, Kong
- Wave 6: ESO, Infisical, Redis-Insight, Mongo-Express
- Wave 7: CNPG operator, CNPG clusters
- Wave 8: Harbor, Harbor-backup (pg_dump CronJob), Actions Runner
- Wave 9+: Applications (Vaultwarden, Kafka, Immich, etc.)
- Wave 10+: yana-stocks services

### Helm values

Use `valuesObject:` (not `values: |`) to avoid YAML indentation issues:

```yaml
helm:
  valuesObject:
    key: value
```

### infrastructure/monitoring/ sync caveat

The `argocd-app-*.yaml` Application manifests in `infrastructure/monitoring/` (like all `argocd-app-*.yaml` files repo-wide) **are** continuously synced — the root `kustomization.yaml` lists them and the `bootstrap` Application applies it with `selfHeal: true`. Two consequences:

- Editing an Application's spec (e.g. Helm values in `argocd-app-monitoring.yaml`) takes effect on **push to GitHub** — no manual apply needed.
- A manual `kubectl apply` of an Application spec that isn't pushed yet is **silently reverted** by the bootstrap app's selfHeal within minutes (confirmed 2026-07-03). Don't bother; push instead.

Non-Application extras in the directory (ExternalSecrets, ClusterSecretStores, RBAC — `eso-*.yaml`, `external-secret*.yaml`) are **not** in the root kustomization and are not synced by anything — apply those manually after committing:

```bash
kubectl apply -f infrastructure/monitoring/<file>.yaml
```

The child apps `argocd-app-monitoring-rules.yaml` and `argocd-app-grafana-dashboards.yaml` create their own persistent child ArgoCD apps that sync `rules/` and `dashboards/` continuously.

### Known permanent OutOfSync (cosmetic, all Healthy — do not fix)

- `actions-runner-controller` — OCI registry limitation
- `argo-rollouts` — cluster-scoped CRDs tracked twice
- `infisical` — bundled nginx chart mutation
- `yana-stocks` / `ml-predictor` Rollout — cosmetic OutOfSync after SSA field-manager migration; diff is always empty, Rollout is Healthy

### immich ignoreDifferences pattern (SSA + ESO + CNPG)

The `immich` app uses `ServerSideApply=true`. Two CRDs require `ignoreDifferences`:

- **ExternalSecret**: ESO injects default fields (`conversionStrategy`, `decodingStrategy`, `metadataPolicy`, `nullBytePolicy`, `deletionPolicy`, `engineVersion`, `mergePolicy`) — use `jqPathExpressions`
- **CNPG Cluster**: The CNPG admission webhook injects ~20 default spec fields (affinity, enablePDB, logLevel, etc.) that aren't in the manifest — use `jqPathExpressions` listing each field. `managedFieldsManagers` does NOT work here because CNPG uses `Update` (not `Apply`) operation, so the injected fields are not tracked under any named field manager.
- The `immich-app-server` Ingress is owned exclusively by the `immich-app` Helm chart — do not add an `immich-ingress.yaml` duplicate to the `immich` kustomization.

### ArgoCD + Argo Rollouts pitfalls

- **Never set `ServerSideApply=false` on a Rollout.** The Rollout CRD uses `x-kubernetes-preserve-unknown-fields` for `.spec.template`, so client-side structured merge diff fails with "field not declared in schema". The app-level `ServerSideApply=true` handles this correctly.
- **Stray `spec.template` blocks in Service definitions** cause the same "field not declared in schema" error. Check multi-resource YAML files (Deployment + Service in one file) to ensure the Service section is not accidentally inheriting content from the Deployment's `spec.template`.
- **`ComparisonError: field not declared in schema` on Rollout `.spec.template`**: Even with `ServerSideApply=true` and per-Application `ServerSideDiff=true` in syncOptions, ArgoCD v3.x requires the **global** `controller.diff.server.side: "true"` flag in `argocd-cmd-params-cm` (set via `configs.params` in the ArgoCD Helm values). Per-Application `ServerSideDiff=true` alone is insufficient — the controller ignores it without the global flag. Fix already applied in `infrastructure/argocd/values.yaml`.
- **Argo Rollouts controller has high restart count (~2/day)** — suspected memory
  leak or OOM. When the controller restarts mid-canary it sometimes fails to
  re-evaluate an in-progress rollout whose timed pause has already expired,
  leaving it permanently `Paused`. Diagnosis: check
  `kubectl get rollout <name> -n <ns> -o jsonpath='{.status.phase} {.status.pauseConditions}'`
  — if phase is `Paused` but the pause startTime is past its duration, the
  controller is stuck. Fix: restart the controller pods and it re-evaluates
  within ~15s:
  ```bash
  kubectl delete pod -n argo-rollouts -l app.kubernetes.io/name=argo-rollouts
  ```
- **`argocd.argoproj.io/refresh` annotation is a no-op if the value doesn't change.** Patching it to the same value twice (e.g. `hard` → `hard`) fires no watch event, so the app never actually refreshes. Alternate values (`hard` → `hard-2`) or remove-then-reapply.
- **Stuck on a stale git revision despite `refresh: hard`?** The `argocd-repo-server`'s local git clone can go stale (suspiciously fast `git_ms` in controller logs — a cache hit, not a real fetch — is the tell). No webhook is configured for these repos, so ArgoCD relies purely on polling + its local clone cache. Fix: `kubectl rollout restart deployment argocd-repo-server -n argocd`, then refresh the Application again.
- **`Sync: Unknown` (not `OutOfSync`) with a `ComparisonError` condition mentioning `spec.strategy.rollingUpdate: Forbidden`** means git specifies `strategy.type: Recreate` (no `rollingUpdate`) but the **live** Deployment still has a stale `rollingUpdate` block from a prior `RollingUpdate` strategy — the server-side dry-run diff itself fails on that combination, so ArgoCD can't even compute sync status, not just report drift. Confirmed 2026-07-17 on `uptime-kuma` (single-replica, RWO Ceph RBD PVC — same deadlock risk as the Harbor case below, git had already been fixed to `Recreate` but the live object never got the corresponding patch). Fix: `kubectl patch deployment <name> -n <ns> --type=merge -p '{"spec":{"strategy":{"rollingUpdate":null,"type":"Recreate"}}}'` — this only changes the strategy field, doesn't restart the running pod, and clears the `ComparisonError` on the next refresh. Same underlying fix as the Harbor deadlock below; check for this pattern on any other single-replica RWO-PVC app if it ever shows `Sync: Unknown`.

### Application source path discipline

All manifests for an app (Deployments, Services, ExternalSecrets, etc.) MUST be inside the directory specified in the Application's `spec.source.path`. Files placed in a parent directory are silently ignored by ArgoCD. For apps with a `manifests/` subdirectory (e.g. `apps/gotify/manifests`), ensure every manifest — including ExternalSecrets — lives inside that subdirectory.

### Harbor: RWO PVC rolling update deadlock

Harbor's `harbor-jobservice` and `harbor-registry` Deployments use `ReadWriteOnce` Ceph RBD PVCs. During a rolling update, if the new pod is scheduled on a different node than the old pod, Kubernetes enters a deadlock:

- The new pod can't start (can't mount the RWO volume held by the old pod on another node)
- The old pod won't terminate (rolling update waits for the new pod to be ready first)

**Symptom:** New RS pods stuck in `ContainerCreating` for hours with no events (events expire after ~1h).

**Fix:** Manually delete the old running pods. Kubernetes releases the PVC, the new pods can mount it, and the old RS is garbage-collected once the new pods become Ready:

```bash
kubectl delete pod -n harbor <old-jobservice-pod> <old-registry-pod>
```

To identify old vs new pods: the new RS pods are the ones in `ContainerCreating`; the old RS pods are the ones `Running` from a different ReplicaSet name.

If both RS have competing pods, check RS revision numbers to confirm which is current:

```bash
kubectl get rs -n harbor <rs-name> -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}'
```

Scale down the old RS to 0 to break the deadlock: `kubectl scale rs -n harbor <old-rs-name> --replicas=0`

### Harbor: jobservice/core CORE_SECRET mismatch after cluster restart

After a cluster restart, ArgoCD may sync and update the `harbor-core` Kubernetes secret shortly after harbor-core pods have already started. This creates a mismatch: harbor-core is running with the old `CORE_SECRET` value, but newly-started jobservice pods read the new value → `401 UNAUTHORIZED` on `/api/v2.0/internalconfig`.

**Symptom:** `harbor-jobservice` CrashLoopBackOff with `http error: code 401, message {"errors":[{"code":"UNAUTHORIZED","message":"only internal service is allowed to call this API"}]}`

**Confirm:** Compare the running harbor-core env vs the current k8s secret:

```bash
kubectl exec -n harbor <harbor-core-pod> -- sh -c 'echo $CORE_SECRET'
kubectl get secret harbor-core -n harbor -o jsonpath='{.data.secret}' | base64 -d
```

**Fix:** Restart harbor-core so it reloads the current secret value:

```bash
kubectl rollout restart deployment harbor-core -n harbor
```

## Network Policies

### Critical rules

1. **Every namespace** gets `default-deny-all` NetworkPolicy
2. **Every operator/controller namespace** needs `allow-kube-apiserver-egress` (ports 443+6443+53)
3. **Ceph CSI OSD egress** requires `CiliumNetworkPolicy` with `toCIDR` — NOT standard NetworkPolicy
4. **Cross-namespace ClusterIP routing** requires `CiliumNetworkPolicy` in Cilium native routing mode — standard NetworkPolicy doesn't work. Confirmed for: Grafana → Prometheus, Grafana → PostgreSQL (yana-stocks). Use `toEndpoints` with pod labels.
5. **ESO webhook disabled** — was blocking syncs. Do NOT re-enable without also adding CiliumNetworkPolicy for node IP ingress
6. **KEDA intra-namespace gRPC (port 9666):** `metrics-apiserver` → `keda-operator` requires an explicit `podSelector: {}` ingress rule on port 9666 in the `allow-keda` policy — `default-deny-all` blocks it otherwise
7. **The first policy to select a pod flips its default from allow to deny — for that whole direction, not just what the new rule covers.** A namespace with zero NetworkPolicies/CiliumNetworkPolicies is fully open. The moment any policy's `endpointSelector`/`podSelector` matches a pod for a given `policyTypes` direction, that pod becomes default-deny for that direction except what's explicitly allowed — by _any_ policy selecting it, not just the new one. Adding a narrow `CiliumNetworkPolicy` to a previously-unrestricted namespace (e.g. to let one app reach a new internal-only Service) can silently break every _other_ egress path that app had — DNS included. If the target namespace has no prior policies, either scope the new rule to only the specific pods that need it, or pair it with a `toEntities: [all]` / `egress: [{}]` catch-all rule restoring the original open posture (see `ciliumnetpol-akan-k8s-docs.yaml` for an example that gets this right).
8. **`cnpg-system`'s `allow-cnpg-operator` NetworkPolicy (`infrastructure/network-policies/netpol-cnpg.yaml`) has a per-namespace egress allowlist, not a wildcard** — the CNPG operator can only reach instance pods (ports 8000/5432/9187) in namespaces explicitly listed there. **Every new CNPG-hosting namespace needs an entry added to this list**, or the operator can never extract that cluster's instance status: it fails forever with `phase: Instance Status Extraction Error: HTTP communication issue` / `dial tcp <pod-ip>:8000: i/o timeout` in the operator's own logs (`kubectl logs -n cnpg-system deploy/cnpg-cloudnative-pg`), even though the cluster's own `allow-cnpg-operator` NetworkPolicy in its own namespace looks correct. Confirmed and fixed 2026-07-16 for `ops-agent-pg` — added when the cluster was created, but its namespace (`ops-agent`) was never added to this allowlist.

### Files

- `infrastructure/network-policies/netpol-infrastructure.yaml` — all infrastructure namespaces
- `infrastructure/network-policies/netpol-cnpg.yaml` — CNPG operator + clusters
- `infrastructure/network-policies/netpol-monitoring.yaml` — monitoring stack
- `infrastructure/network-policies/netpol-apiserver-egress.yaml` — kube-apiserver egress for all namespaces
- `infrastructure/cilium/ciliumnetpol-ceph-osd.yaml` — Ceph OSD egress (toCIDR 192.168.22.0/24, ports 6802-6809)
- `infrastructure/cilium/ciliumnetpol-grafana-prometheus.yaml` — Grafana → Prometheus (cross-namespace ClusterIP)
- `infrastructure/cilium/ciliumnetpol-grafana-pg.yaml` — Grafana → PostgreSQL auth-service-pg in yana-stocks (cross-namespace ClusterIP)
- `infrastructure/cilium/ciliumnetpol-pve-scrape.yaml` — Prometheus → Proxmox node exporters
- `infrastructure/cilium/ciliumnetpol-eso-webhook.yaml` — ESO webhook (currently unused — webhook disabled)
- `infrastructure/cilium/ciliumnetpol-ops-agent-to-redis.yaml` — ops-agent → shared cluster Redis (prompt cache)
- `infrastructure/cilium/ciliumnetpol-ops-agent-to-proxmox.yaml` — ops-agent → Proxmox API (toCIDR, same 3 IPs as the Ceph OSD policy, port 8006)
- `infrastructure/cilium/ciliumnetpol-ops-agent-to-prometheus.yaml` — ops-agent's observability subagent → Prometheus (port 9090)
- `infrastructure/cilium/ciliumnetpol-ops-agent-to-alertmanager.yaml` — ops-agent's observability subagent → Alertmanager (port 9093)
- `infrastructure/cilium/ciliumnetpol-ops-agent-to-minio.yaml` — ops-agent's minio subagent → MinIO S3 API health endpoints (port 9000)

### Adding a new namespace

1. Add `default-deny-all` to appropriate netpol file
2. Add specific ingress/egress policies
3. Add `allow-kube-apiserver-egress` to `netpol-apiserver-egress.yaml` if namespace has operators
4. Apply and commit

## Infisical Webhook (CRITICAL)

The infisical bundled nginx creates `infisical-ingress-nginx-admission` ValidatingWebhookConfiguration which blocks ALL ingress and ExternalSecret creation cluster-wide when it times out.

**Permanent fix applied:**

- `infisical-ingress-nginx-controller` scaled to 0 replicas
- `admissionWebhooks.enabled: false` in infisical values
- `failurePolicy: Ignore` patched on the webhook (in `ignoreDifferences`)
- Admission service deleted

**If webhook reappears and blocks:**

```bash
kubectl delete validatingwebhookconfiguration infisical-ingress-nginx-admission 2>/dev/null; true
kubectl delete service infisical-ingress-nginx-controller-admission -n infisical 2>/dev/null; true
```

**If infisical ingress breaks** (reverts to `infisical-nginx` class after sync):

```bash
kubectl patch ingress infisical-ingress -n infisical --type='json' \
  -p='[{"op":"replace","path":"/spec/ingressClassName","value":"nginx"},{"op":"add","path":"/spec/tls","value":[{"hosts":["infisical.yanatech.co.uk"],"secretName":"wildcard-yanatech-tls"}]},{"op":"replace","path":"/spec/rules","value":[{"host":"infisical.yanatech.co.uk","http":{"paths":[{"path":"/","pathType":"Prefix","backend":{"service":{"name":"infisical-infisical-standalone-infisical","port":{"number":8080}}}}]}}]}]'
```

## Kong API Gateway

- **Namespace:** `kong`
- **Chart:** `kong/ingress` 0.24.0 (Kong 3.9, DB-less)
- **MetalLB VIP:** `192.168.33.202`
- **External URL:** `https://api-gateway.yanatech.co.uk`
- **Mode:** DB-less — routes defined via Kubernetes Ingress with `ingressClassName: kong` or KongIngress CRDs
- **No admin UI** in OSS mode

### Webhook timeout (IMPORTANT)

The `kong-controller-kong-validations` ValidatingWebhookConfiguration has three webhooks, all with `timeoutSeconds: 10` by default. Due to Cilium native routing, the kube-apiserver→webhook call takes ~10s each, causing timeouts in multiple operators.

**All three webhooks must have `timeoutSeconds: 5`:**

| Index | Name                               | Why 5s matters                                                                                                                                                    |
| ----- | ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0     | `secrets.credentials.validation.*` | Intercepts ALL secrets cluster-wide — was blocking cert-manager SSA PATCH on TLS secrets (`context deadline exceeded` after two sequential 10s calls = 20s total) |
| 1     | `secrets.plugins.validation.*`     | Same — also intercepts all secrets cluster-wide                                                                                                                   |
| 2     | `services.validation.*`            | Intercepts all Service CREATE/UPDATE — was breaking Strimzi (fabric8 HTTP client timeout)                                                                         |

**Fix applied:** `timeoutSeconds` patched to `5` on all three webhook entries. `ignoreDifferences` in `argocd-app-kong.yaml` (indices 0, 1, 2) prevents ArgoCD from reverting this.

**Do not increase `timeoutSeconds` back to 10** — it will break cert-manager secret writes AND the Strimzi operator.

### Adding a Kong route

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-route
  namespace: my-namespace
  annotations:
    konghq.com/strip-path: "true"
    konghq.com/plugins: "jwt-auth,rate-limiting"
spec:
  ingressClassName: kong
  rules:
    - http:
        paths:
          - path: /api/my-service
            pathType: Prefix
            backend:
              service:
                name: my-service
                port:
                  number: 3000
```

## yana-stocks

### Namespace

`yana-stocks`

### Services

```
apps/yana-stocks/
├── namespace.yaml
├── argocd-app-yana-stocks.yaml    # app-of-apps
├── kong/                          # KongConsumer (auth-service), JWT/CORS plugins, ingress routes
├── auth-service/                  # Go, CNPG cluster (auth-service-pg), golang-migrate at startup
├── profile-service/               # NestJS, MongoDB, KEDA ScaledObject (min 1, users.registered)
├── price-ingestor/                # Python, KEDA ScaledObject
├── price-processor/               # NestJS, KEDA ScaledObject (min 1, stocks.prices.raw)
├── sentiment-analyzer/            # Python, KEDA ScaledObject (min 0, stocks.prices.processed)
├── ml-predictor/                  # Python, Argo Rollouts canary
├── portfolio-service/             # NestJS, KEDA ScaledObject (min 1, prices.processed + users.registered)
├── portfolio-api/                 # NestJS, KEDA ScaledObject (min 1, prices.processed + signals)
├── frontend/                      # Next.js, ingress stocks.yanatech.co.uk
└── turbo-cache/                   # ducktors/turborepo-remote-cache → MinIO bucket `turborepocache`
```

### Images

All pushed to `harbor.yanatech.co.uk/yana-stocks/<service>:<tag>`

### CNPG for auth-service

Separate CNPG cluster `auth-service-pg` in `yana-stocks` namespace (not shared with pg-main).
Migrations run at pod startup via golang-migrate (no initContainer needed).
Cluster has 2 instances (primary + 1 replica) with barman backup to MinIO `s3://cnpg-backups/auth-service-pg/` and a daily ScheduledBackup at 01:00. MinIO credentials provisioned via ExternalSecret `cnpg-minio-credentials` (Infisical keys `/cnpg-clusters/MINIO_ACCESS_KEY_ID` + `/cnpg-clusters/MINIO_SECRET_KEY`).

### Kafka topics

```
users.registered
stocks.prices.raw
stocks.prices.processed
stocks.signals.sentiment
stocks.signals.prediction
stocks.portfolio.events
```

Broker: `kafka-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092`

**Fixed 2026-07-16:** `apps/kafka/yana-stocks-topics.yaml`'s `KafkaTopic` resources previously used hyphenated `metadata.name`s (`stocks-prices-raw`, etc.) that didn't match the dotted names above at all — `packages/kafka-client/src/topics.ts` is what every producer/consumer actually connects with, and Kafka auto-created the real dotted-name topics on first use with 1 partition and no explicit retention config, while the hyphenated `KafkaTopic` resources quietly managed a completely separate, never-produced-to set of topics. `metadata.name` now matches the dotted topic names exactly, so Strimzi manages the real topics.

**Follow-up completed 2026-07-16:** all topics above (and `notifications.email.send`) were bumped from 1 to 3 partitions — `users.registered` first as a pilot (confirmed consumer group lag=0 immediately before, broker partition count actually changed via `kafka-topics.sh --describe`, and `profile-service`'s consumer group rebalanced onto the new partitions cleanly with no errors), then the rest once that validated. KEDA's `maxReplicaCount` on price-ingestor/price-processor/sentiment-analyzer/profile-service/portfolio-service/portfolio-api can now actually take effect.

### KEDA ScaledObject pattern (price-ingestor, price-processor, sentiment-analyzer, profile-service, portfolio-service, portfolio-api)

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: price-ingestor-scaler
  namespace: yana-stocks
spec:
  scaleTargetRef:
    name: price-ingestor
  minReplicaCount: 0
  maxReplicaCount: 5
  triggers:
    - type: kafka
      metadata:
        bootstrapServers: kafka-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092
        consumerGroup: price-ingestor
        topic: stocks.prices.raw
        lagThreshold: "10"
```

**Don't forget:** if the target Deployment's manifest also declares a static `replicas:` field (all of these do), the owning ArgoCD Application needs an `ignoreDifferences` entry for that Deployment's `/spec/replicas` — otherwise self-heal resets it to the static value on every sync, which KEDA then scales back down moments later (visible as pod churn right after every routine sync). See `argocd-app-yana-stocks.yaml` for the six existing entries.

### Argo Rollouts pattern (ml-predictor)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: ml-predictor
  namespace: yana-stocks
spec:
  replicas: 2
  strategy:
    canary:
      steps:
        - setWeight: 10
        - pause: { duration: 5m }
        - analysis:
            templates:
              - templateName: ml-predictor-success-rate
        - setWeight: 50
        - pause: { duration: 5m }
        - setWeight: 100
  selector:
    matchLabels:
      app: ml-predictor
  template:
    metadata:
      labels:
        app: ml-predictor
    spec:
      containers:
        - name: ml-predictor
          image: harbor.yanatech.co.uk/yana-stocks/ml-predictor:latest
```

## shared-services

### Repo

`github.com/akann/shared-services` — standalone Turborepo (own remote, not a yana-stocks subdirectory). App manifests live in **its own repo** (`k8s/`), yanatech-style — only cluster-wide resources (Kafka topics, the ArgoCD Application, NetworkPolicies) live here in `k8s-apps`.

Since this repo is private, ArgoCD needs its own `repository`-type Secret to clone it (`repo-shared-services` in the `argocd` namespace, same shape as `repo-yanatech`/`repo-akan` — `type: git`, `username`/`password` (fine-grained PAT), `url`). Without it, the Application shows `ComparisonError: ... authentication required: Repository not found.` The `argocd-app-shared-services.yaml` Application also sets `source.directory.recurse: true` since `k8s/` has nested subfolders (`email-api/kong/`, etc.) — yanatech's flat `k8s/` doesn't need this.

### Namespace

`shared-services`

### Apps

```
email-api          # NestJS HTTP — POST /api/email/send, validates + queues onto Kafka, returns 202
email-service       # NestJS Kafka consumer — sends via swappable EmailProvider (SMTP2GO first), single attempt + DLQ on failure (no retry — see UPDATES.md)
shared-api-docs     # Redocly OpenAPI hub for email-api, Authentik-protected (shared-api-docs.yanatech.co.uk)
```

### Kafka topics (in `apps/kafka/shared-services-topics.yaml`)

```
notifications.email.send     # 24h retention — producer: email-api, consumer: email-service
notifications.email.failed   # 30d retention — DLQ, producer: email-service
```

Broker: `kafka-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092` (same cluster-wide Strimzi broker as yana-stocks)

Same 2026-07-16 fix as yana-stocks' topics above applied here too — see that section for the full incident. `notifications.email.send` is stuck at 1 partition (already live when fixed); `notifications.email.failed` didn't exist live yet at fix time, so it was created correctly with 3 partitions from the start, no follow-up needed.

### Routing

`email-api` is reached only via Kong (`https://api-gateway.yanatech.co.uk/api/email/send`), gated by a `key-auth` plugin (not an in-app guard) — same pattern as the JWT plugin for yana-stocks. A `CiliumNetworkPolicy`-free plain `NetworkPolicy` restricts ingress to `email-api`'s ClusterIP to the `kong` namespace only, so callers can't bypass the key-auth check by hitting the Service directly.

### KEDA ScaledObject (email-service)

Same shape as yana-stocks' pattern above — `minReplicaCount: 0`, triggers on `notifications.email.send` consumer lag.

### Images

`harbor.yanatech.co.uk/shared-services/<app>:<tag>` — `email-api`, `email-service`, `shared-api-docs`. Pushed via a project-scoped Harbor robot account (`robot$shared-services+ci`), not a borrowed/shared credential — Harbor's per-project robot accounts don't carry access to other projects, so a new project needs its own project + robot account (`POST /api/v2.0/projects`, then `POST /api/v2.0/robots` with `level: project` + `permissions[].namespace` — note `GET/POST .../projects/{id}/robots` 404s on this Harbor version (v2.15.1); the system-wide `/api/v2.0/robots` endpoint works for both system- and project-level robots).

### CI runner

`runners-shared-services` — a dedicated per-repo ARC runner scale set (`infrastructure/actions-runner/argocd-app-runners-shared-services.yaml`), same pattern as `runners-yana-stocks`/`runners-k8s-apps`. GitHub-hosted `ubuntu-latest` **cannot** build/push here — `harbor.yanatech.co.uk` doesn't resolve outside the homelab network. Only the `docker` job needs the self-hosted runner; `quality`/`gitops` stay on `ubuntu-latest`.

## ml (RAG chatbot over homelab docs)

### Repo

`github.com/akann/ml` — standalone Turborepo, meant to grow into more than one ML app over time (each future app gets its own path under `ml.yanatech.co.uk/<app>`, path-based routing on one shared domain — a deliberate deviation from this cluster's usual one-subdomain-per-app convention). App manifests live in **its own repo** (`k8s/`), shared-services-style. Needs its own `repo-ml` git credential Secret in `argocd` (same shape/PAT-reuse as `repo-akan`) and its own `runners-ml` ARC scale set — same two prerequisites every new private repo needs (see shared-services section above).

### Namespace

`k8s-docs` (not `ml` — each app in this repo gets its own namespace, matching the one-namespace-per-app convention; the repo name and the namespace name are intentionally different)

### Apps

```
k8s-docs   # NestJS — RAG chatbot over k8s-apps' docs. Ingest webhook (public) + query endpoint (internal-only, see below)
```

### Content scope — deliberately narrow

Only `k8s-apps` is ingested, not the other private repos in this workspace. `k8s-apps` is the only one of them that's public on GitHub, and the chat page (`akan.nkweini.org/k8s-docs`) is public with no page-level auth — indexing a private repo's docs would let anyone read them via the chatbot as a side channel. **Guardrail:** adding another (private) repo to `k8s-apps/.github/workflows/ingest-docs.yml`'s pattern without first gating the chat page behind Authentik reopens this. The ingest workflow triggers on any `**/*.md` change anywhere in the repo, not just `CLAUDE.md`/`docs/`/`README.md`, so per-app/infra READMEs and `UPDATES.md` get indexed too.

**Fixed 2026-07-16:** the workflow's payload-assembly script used to pass full file contents through `jq --arg`/`--argjson` and `curl -d` — all argv-based — which silently fails once a commit's combined changed-`.md` content crosses the ~128KB single-argument exec limit (`jq: Argument list too long`, exit 126). A commit touching this file's own `CLAUDE.md`+`README.md` tripped it (164KB combined). Rewritten to route every file's content through disk instead (`jq --rawfile`/`--slurpfile`, `curl --data-binary @file`), which has no such ceiling.

### `/query` is not on the public Ingress at all

`ml.yanatech.co.uk/k8s-docs` only routes `/ingest/webhook` and `/health`. The query endpoint is reachable only from the `akan` namespace, over internal Service DNS (`k8s-docs.k8s-docs.svc.cluster.local:3000`), enforced by `infrastructure/cilium/ciliumnetpol-akan-k8s-docs.yaml` — see Network Policies rule 7 above for the failure mode this guards against. An API key is checked in-app too, but it's defense-in-depth; the network policy is what actually keeps it unreachable from the internet. `akan`'s Next.js server (`apps/akan/app/api/k8s-docs/query/route.ts`) is the only caller, holding the key server-side.

### CNPG

Dedicated `k8s-docs-pg` cluster in the `k8s-docs` namespace (see Databases section above). `bootstrap.initdb.secret` names a secret CNPG does **not** auto-generate — it must be pre-created via its own `ExternalSecret` (`k8s-docs-db-credentials`, type `kubernetes.io/basic-auth`), same pattern as `apps/immich/external-secret.yaml`'s `immich-db-credentials`. Missing this hangs the bootstrap job indefinitely on `secret not found`, not an obvious error to trace back to a missing manifest.

### Images

`harbor.yanatech.co.uk/ml/<app>:<tag>` — `k8s-docs`. Pushed via a project-scoped Harbor robot account (`robot$ml+ci`), same per-project-credential pattern as `shared-services`.

### CI runner

`runners-ml` — same pattern as `runners-shared-services`.

## dove-house-tt (Dove House Table Tennis Club members app)

### Repo

`github.com/akann/dove-house-tt` — standalone Turborepo (Next.js 16 + better-auth + Drizzle), **private** (akan-style): needs the `repo-dove-house-tt` git credential Secret in the `argocd` namespace and a `ghcr-secret` dockerconfigjson in the app namespace. No self-hosted runner needed (images go to ghcr.io, built on `ubuntu-latest`). App manifests live in **its own repo** (`k8s/dove-house-tt/`).

### Namespace / domain

`dove-house-tt` — served at `https://dovehousett.org` (+ www redirect). Third DNS zone on the cluster: own Cloudflare token (`/cert-manager/api-token-dovehousett`), own solver in `letsencrypt-prod`, own reflected wildcard cert `wildcard-dovehousett-tls`.

### Images

`ghcr.io/akann/dove-house-tt` (Next standalone runner) + `ghcr.io/akann/dove-house-tt-migrate` (full node_modules; runs `drizzle-kit migrate` as the deployment's initContainer — the pruned standalone image can't run drizzle migrations). Both packages are **private** — pulled via the `ghcr-secret` in the namespace (akan pattern).

### CNPG

Dedicated `dove-house-tt-pg` cluster (2 instances, plain `ghcr.io/cloudnative-pg/postgresql:16`), same pre-created basic-auth credentials pattern as k8s-docs (`dove-house-tt-db-credentials` via ExternalSecret — CNPG won't auto-generate it). `DATABASE_URL` is composed manually in Infisical (`/dove-house-tt/DATABASE_URL`) against `dove-house-tt-pg-rw.dove-house-tt.svc.cluster.local:5432`.

### Staging environment

A second, self-contained deployment at `https://stg.dovehousett.org`, sourced from the same repo's `staging` branch (`k8s/dove-house-tt-stg/`, own ArgoCD Application `apps/dove-house-tt-stg/`, own namespace `dove-house-tt-stg`). Reuses the existing `repo-dove-house-tt` git credential (not branch-scoped) but needs its own `ghcr-secret` in the new namespace (Secrets don't cross namespaces) and its own Infisical secrets under `/dove-house-tt-stg/`. CNPG is a minimal single-instance `dove-house-tt-stg-pg` cluster with no ScheduledBackup — disposable/re-seedable test data, deliberately not resilient to a node drain. TLS reuses the existing `wildcard-dovehousett-tls` wildcard cert (already covers `*.dovehousett.org`), so no new Certificate was needed — only the network-policy blocks (`netpol-apps.yaml`, `netpol-cnpg.yaml`, `netpol-apiserver-egress.yaml`) and the DNS record for the subdomain (created directly in Cloudflare, outside git) were.

## Useful Commands

```bash
# ArgoCD (alias set on k8s-cp-1)
argocd app list
argocd app sync <app-name>
argocd app get <app-name>

# Force delete infisical webhook (run when ingress/ESO creation fails)
kubectl delete validatingwebhookconfiguration infisical-ingress-nginx-admission 2>/dev/null; true

# Check all non-healthy apps
argocd app list | grep -v "Synced.*Healthy"

# CNPG cluster status
kubectl get cluster -A

# Kafka topics
kubectl get kafkatopic -n kafka

# Check ESO sync status
kubectl get externalsecret -A

# Headlamp SA token (SSO broken upstream)
kubectl create token headlamp -n headlamp --duration=8760h
```

## Services URLs

| Service                             | URL                                  |
| ----------------------------------- | ------------------------------------ |
| ArgoCD                              | https://argocd.yanatech.co.uk        |
| Authentik                           | https://authentik.yanatech.co.uk     |
| Grafana                             | https://grafana.yanatech.co.uk       |
| Immich                              | https://photos.yanatech.co.uk        |
| Infisical                           | https://infisical.yanatech.co.uk     |
| Harbor                              | https://harbor.yanatech.co.uk        |
| Nextcloud                           | https://cloud.yanatech.co.uk         |
| Kong                                | https://api-gateway.yanatech.co.uk   |
| MinIO Console                       | https://minio-console.yanatech.co.uk |
| MongoDB UI                          | https://mongo.yanatech.co.uk         |
| Redis UI                            | https://redis.yanatech.co.uk         |
| Headlamp                            | https://headlamp.yanatech.co.uk      |
| Uptime Kuma                         | https://status.yanatech.co.uk        |
| Kafka UI                            | https://kafka-ui.yanatech.co.uk      |
| Argo Rollouts                       | https://rollouts.yanatech.co.uk      |
| pgAdmin                             | https://pgadmin.yanatech.co.uk       |
| Apicurio                            | https://apicurio.yanatech.co.uk      |
| yana-stocks                         | https://stocks.yanatech.co.uk        |
| Akan personal site                  | https://akan.nkweini.org             |
| K8s Docs Chat (k8s-docs, public UI) | https://akan.nkweini.org/k8s-docs    |
