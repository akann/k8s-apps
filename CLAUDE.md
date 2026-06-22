# k8s-apps — Claude Code Instructions

## Overview
GitOps repository for Akan's homelab Kubernetes cluster. All infrastructure and applications are defined here and deployed via ArgoCD. Everything must be committed to git — nothing deployed manually without a follow-up commit.

**Principle:** GitOps-first. Correctness over speed. If it's not in git, it doesn't exist.

## Repository Location
- **Remote:** `github.com/akann/k8s-apps`
- **Local on cluster:** `~/repo/k8s-apps` on `k8s-cp-1` (192.168.22.21)
- **ArgoCD:** `https://argocd.yanatech.co.uk` (v3.4.2)

## Cluster
- **6-node Kubernetes** (kubeadm, v1.32): control planes k8s-cp-1/2/3 (192.168.22.21-23), workers k8s-worker-1/2/3 (192.168.22.31-33)
- **3-node Proxmox:** pve1-3 (192.168.22.11-13)
- **Domain:** `yanatech.co.uk`
- **kubectl alias on k8s-cp-1:** `argocd='argocd --grpc-web'`

## Repo Structure
```
k8s-apps/
├── bootstrap.sh                    # Ordered app deployment for fresh cluster
├── apps/                           # Application ArgoCD apps
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
│   └── yana-stocks/               # yana-stocks microservices (Phase 4)
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
- **Load Balancer:** MetalLB, pool `192.168.22.200-249`
  - `192.168.22.200` — ingress-nginx
  - `192.168.22.201` — infisical bundled nginx (scaled to 0, do not use)
  - `192.168.22.202` — Kong API Gateway
- **Ingress:** ingress-nginx at `192.168.22.200`
- **TLS:** cert-manager, Let's Encrypt wildcard `wildcard-yanatech-tls` via Cloudflare DNS-01, reflected to all namespaces via Reflector

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
- **CNPG pg-main:** `pg-main-rw.cnpg-clusters.svc.cluster.local:5432` — shared cluster for vaultwarden, authentik, nextcloud, infisical, apicurio
- **Immich postgres:** `immich-postgres-rw.immich.svc.cluster.local:5432` — dedicated CNPG cluster using `ghcr.io/tensorchord/cloudnative-vectorchord:16-1.1.1`
- **MongoDB:** `mongodb-headless.mongodb.svc.cluster.local:27017` (replicaSet=rs0)
- **Redis:** `redis-master.redis.svc.cluster.local:6379`
- **MinIO:** `minio.minio.svc.cluster.local:9000`

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
- Wave 8: Harbor, Actions Runner
- Wave 9+: Applications (Vaultwarden, Kafka, Immich, etc.)
- Wave 10+: yana-stocks services

### Helm values
Use `valuesObject:` (not `values: |`) to avoid YAML indentation issues:
```yaml
helm:
  valuesObject:
    key: value
```

### infrastructure/monitoring/ bootstrap caveat
Files in `infrastructure/monitoring/` are applied once during the initial bootstrap (when the monitoring ArgoCD app first synced from the directory before converting itself to a Helm chart source). New files added to that directory are **not auto-synced** by any running ArgoCD app — apply them manually:
```bash
kubectl apply -f infrastructure/monitoring/<file>.yaml
```
The child apps `argocd-app-monitoring-rules.yaml` and `argocd-app-grafana-dashboards.yaml` are exceptions — they create their own persistent child ArgoCD apps that do continuously sync. For new persistent extras (ExternalSecrets, ClusterSecretStores, RBAC), either apply manually or create a dedicated `monitoring-extras` ArgoCD Application.

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
- **MetalLB VIP:** `192.168.22.202`
- **External URL:** `https://api-gateway.yanatech.co.uk`
- **Mode:** DB-less — routes defined via Kubernetes Ingress with `ingressClassName: kong` or KongIngress CRDs
- **No admin UI** in OSS mode

### Webhook timeout (IMPORTANT)
The `kong-controller-kong-validations` ValidatingWebhookConfiguration intercepts all Service CREATE/UPDATE cluster-wide. Due to Cilium native routing, the kube-apiserver→webhook call takes ~10s, which exceeds Strimzi's fabric8 HTTP client timeout and causes the operator to crash-loop.

**Fix applied:** `timeoutSeconds` patched to `5` on the services webhook so it fails-open (failurePolicy: Ignore) before Strimzi times out. `ignoreDifferences` in `argocd-app-kong.yaml` prevents ArgoCD from reverting this.

**Do not increase `timeoutSeconds` back to 10** — it will break the Strimzi operator again.

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

## yana-stocks (Phase 4)

### Namespace
`yana-stocks`

### Services to deploy
```
apps/yana-stocks/
├── namespace.yaml
├── argocd-app-yana-stocks.yaml    # app-of-apps
├── kong/                          # KongConsumer (auth-service), JWT/CORS plugins, ingress routes
├── auth-service/                  # Go, CNPG cluster (auth-service-pg), golang-migrate at startup
├── profile-service/               # NestJS, MongoDB, consumes users.registered Kafka topic
├── price-ingestor/                # Python, KEDA ScaledObject
├── price-processor/               # NestJS
├── sentiment-analyzer/            # Python, KEDA ScaledObject
├── ml-predictor/                  # Python, Argo Rollouts canary
├── portfolio-service/             # NestJS
├── portfolio-api/                 # NestJS
└── frontend/                      # Next.js, ingress stocks.yanatech.co.uk
```

### Images
All pushed to `harbor.yanatech.co.uk/yana-stocks/<service>:<tag>`

### CNPG for auth-service
Separate CNPG cluster `auth-service-pg` in `yana-stocks` namespace (not shared with pg-main).
Migrations run at pod startup via golang-migrate (no initContainer needed).

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: auth-service-pg
  namespace: yana-stocks
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:16
  bootstrap:
    initdb:
      database: yana_stocks
      owner: yana_stocks
      secret:
        name: auth-service-pg-credentials
  storage:
    size: 10Gi
    storageClass: ceph-rbd
```

### Kafka topics (already created)
```
users.registered
stocks.prices.raw
stocks.prices.processed
stocks.signals.sentiment
stocks.signals.prediction
stocks.portfolio.events
```
Broker: `kafka-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092`

### KEDA ScaledObject pattern (price-ingestor, sentiment-analyzer)
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
        - pause: {duration: 5m}
        - setWeight: 50
        - pause: {duration: 5m}
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

| Service | URL |
|---|---|
| ArgoCD | https://argocd.yanatech.co.uk |
| Authentik | https://authentik.yanatech.co.uk |
| Grafana | https://grafana.yanatech.co.uk |
| Immich | https://photos.yanatech.co.uk |
| Infisical | https://infisical.yanatech.co.uk |
| Harbor | https://harbor.yanatech.co.uk |
| Nextcloud | https://cloud.yanatech.co.uk |
| Kong | https://api-gateway.yanatech.co.uk |
| MinIO Console | https://minio-console.yanatech.co.uk |
| MongoDB UI | https://mongo.yanatech.co.uk |
| Redis UI | https://redis.yanatech.co.uk |
| Headlamp | https://headlamp.yanatech.co.uk |
| Uptime Kuma | https://status.yanatech.co.uk |
| Kafka UI | https://kafka-ui.yanatech.co.uk |
| Argo Rollouts | https://rollouts.yanatech.co.uk |
| pgAdmin | https://pgadmin.yanatech.co.uk |
| Apicurio | https://apicurio.yanatech.co.uk |
| yana-stocks | https://stocks.yanatech.co.uk |
