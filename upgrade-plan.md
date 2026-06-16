# Homelab Upgrade & Expansion Plan
_Last updated: 2026-06-04_

## Context

3-node Proxmox cluster, 6-node Kubernetes, 48 vCPUs / 192GB RAM / 8.4TiB Ceph.
Current stable services: Vaultwarden, Authentik, Grafana/Loki, ArgoCD, Kafka, Nextcloud, pgAdmin4, Gotify, Headlamp, Uptime Kuma, Velero, Goldilocks, Descheduler, Kured, Reloader, Harbor, Infisical.
All databases on CNPG pg-main (3-instance PG18 cluster). pg1 (VM 110) decommissioned 2026-06-04.
Immich removed — pending fresh deploy once CNPG vchord/GLIBC issue resolved.

## Goals

- ✅ Replace pg1 with CloudNativePG
- Build a private platform for multiple production apps (forex trading, e-commerce, etc.)
- Each product in its own monorepo (e.g. `yana-forex`, `yana-ecommerce`); k8s manifests in `k8s-apps`
- ✅ CI/CD fully on-LAN: source repo → Actions Runner → Harbor → ArgoCD → cluster
- ✅ Replace Flannel with Cilium (native routing over existing OSPF mesh)
- ✅ Sync waves added to bootstrap.sh (ApplicationSet migration deferred)
- Canary / blue-green deployments via Argo Rollouts before first production app goes live
- "Doing it right" is the priority over speed

---

## Repo Structure (target)

```
github.com/akann/k8s-apps          # all k8s manifests (GitOps)
github.com/akann/yana-forex         # forex platform monorepo (source + Dockerfile)
github.com/akann/yana-ecommerce     # e-commerce monorepo (source + Dockerfile)
github.com/akann/yana-<app>         # future apps follow same pattern
```

### k8s-apps target layout

```
k8s-apps/
├── bootstrap/
│   ├── applicationset-infrastructure.yaml
│   └── applicationset-apps.yaml
├── apps/
│   ├── <existing apps>/
│   ├── yana-forex/
│   │   ├── argocd-app-yana-forex-api.yaml       # one ArgoCD app per microservice
│   │   ├── argocd-app-yana-forex-worker.yaml
│   │   └── manifests/
│   │       ├── rollout.yaml                      # Argo Rollouts, not Deployment
│   │       ├── service.yaml
│   │       ├── ingress.yaml
│   │       └── hpa.yaml
│   └── yana-ecommerce/
│       └── ...
└── infrastructure/
    ├── <existing infrastructure>/
    ├── cilium/
    ├── harbor/
    ├── cnpg/
    ├── cnpg-clusters/
    ├── actions-runner/
    ├── eso/
    ├── infisical/
    ├── tempo/
    ├── otel-collector/
    ├── apicurio/
    ├── keda/
    ├── kong/
    ├── argo-rollouts/
    └── network-policies/
```

### CI/CD pipeline (per product repo)

```
git push → github.com/akann/yana-forex
  → Actions Runner (on-cluster) builds image
  → pushes to harbor.yanatech.co.uk/yana-forex/<service>:<sha>
  → updates image tag in k8s-apps/apps/yana-forex/manifests/
  → ArgoCD detects change → deploys via Argo Rollouts (canary/blue-green)
```

---

## Outstanding items / Blockers

- **Headlamp SSO** — blocked by upstream bug (Headlamp 0.42.0, GitHub issues #3884, #4789, #4876, #5025).
  Currently running with service account token (`8760h`). **Revisit on Headlamp 0.43.0+.**
  Token will expire — set a calendar reminder or automate renewal via CronJob.

- **Immich** — removed 2026-06-04. Blocked by: vchord 1.1.1 requires GLIBC_2.33, CNPG bootstrap uses GLIBC_2.31 (Bullseye). Resolution: CNPG 1.29 Image Catalog or bookworm-based custom image. Fresh deploy when resolved.

- **Velero namespace list** — currently hardcoded `--include-namespaces`. Switch to `--exclude-namespaces` so new apps are covered automatically.

- **ESO secret migration** — ESO + Infisical deployed and connected. Next step: populate Infisical with all 14 bootstrap secrets and create ExternalSecret CRDs for each namespace.

---

## Phase 0 — Foundation ✅ COMPLETE

### 0.1 — Cilium (replace Flannel) ✅ DONE 2026-06-04
Native routing mode, kube-proxy replaced, Hubble enabled at `hubble.yanatech.co.uk`.
One node at a time migration. Kafka + ingress-nginx PDBs deleted before each drain.

### 0.2 — Expand MetalLB pool ✅ DONE 2026-06-04
Pool expanded to `192.168.22.200-249` (50 IPs). pfSense NAT already covered full range.

### 0.3 — Sync waves + bootstrap.sh ✅ DONE 2026-06-04
All 29 ArgoCD apps annotated with sync-wave (0-7). bootstrap.sh rewritten with wave-grouped ordering.
ApplicationSet migration deferred to dedicated session — hybrid Helm/git-directory apps need more design.

---

## Phase 1 — Platform Infrastructure ✅ COMPLETE (1.5 in progress)

### 1.1 — Harbor ✅ DONE 2026-06-04
`harbor.yanatech.co.uk` — Authentik OIDC, projects: infra/yana-forex/yana-ecommerce.
Harbor admin login fallback: `https://harbor.yanatech.co.uk/account/sign-in?redirect_url=/harbor/projects`

### 1.2 — Actions Runner Controller ✅ DONE 2026-06-04
New ARC (gha-runner-scale-set 0.9.3) via OCI registry. Runner sets: k8s-apps/yana-forex/yana-ecommerce, scale 0→4.
Docker-in-Docker not available in Kubernetes container mode — image builds use buildah on a node or kaniko.

### 1.3 — CloudNativePG + migrations ✅ DONE 2026-06-04
pg-main: 3-instance PG18, Barman WAL → B2 `yanatech-cnpg`. Migrations complete:
- ✅ Vaultwarden → pg-main-rw.cnpg-clusters
- ✅ Authentik → pg-main-rw.cnpg-clusters
- ✅ Nextcloud → pg-main-rw.cnpg-clusters (config.php must also be patched, not just k8s secret)
- ❌ Immich — blocked by vchord GLIBC issue, removed, pending fresh deploy
- pg1 (VM 110) decommissioned 2026-06-04

### 1.4 — (merged into 1.3)

### 1.5 — ESO + Infisical 🔄 IN PROGRESS
- ✅ Infisical at `infisical.yanatech.co.uk` (standalone chart, CNPG pg-main, Redis, email/password auth)
- ✅ ESO deployed in `external-secrets` namespace
- ✅ ClusterSecretStore `infisical` connected (Valid, ReadOnly)
- 🔄 Populating Infisical with bootstrap secrets + writing ExternalSecret CRDs

Key config notes:
- Infisical OIDC SSO requires paid license — email/password auth only
- `hostAPI: https://infisical.yanatech.co.uk/api` must be set in ClusterSecretStore
- ESO API version: `external-secrets.io/v1`, field: `environmentSlug` (not `envSlug`)
- Infisical project slug: `k8s-homelab`, environment: `prod`
- Machine identity `eso-k8s` must be added to project members in Infisical UI
- Bundled ingress-nginx disabled via `infisical.ingress.nginx.enabled: false` + `ignoreDifferences`

---

## Phase 2 — Observability Stack
_Must be complete before first microservice goes to production. You cannot do canary releases without measurable signals._

### 2.1 — Tempo (distributed tracing backend)
- **Namespace:** `monitoring` (alongside existing kube-prometheus-stack)
- **Helm chart:** `grafana/tempo-distributed` or `grafana/tempo` (single binary to start)
- **Storage:** ceph-rbd PVC
- **Grafana datasource:** wired in alongside existing Loki + Prometheus
- **Manifest:** `infrastructure/tempo/argocd-app-tempo.yaml`

### 2.2 — OTel Collector
- **Namespace:** `monitoring`
- **Role:** single ingestion endpoint for all services → routes to Tempo (traces), Loki (logs), Prometheus (metrics)
- **Endpoint:** `otel-collector.monitoring.svc.cluster.local:4317` (gRPC) / `:4318` (HTTP)
- **Manifest:** `infrastructure/otel-collector/argocd-app-otel-collector.yaml`
- All new microservices instrument with OpenTelemetry SDK pointing at this endpoint
- Existing services (Nextcloud, Immich etc.) do not need retrofitting

### 2.3 — Apicurio Registry (schema registry)
**Why now:** Forex tick data (price, volume, OHLCV) and order events must have versioned schemas before producers and consumers are written. Retrofitting schemas onto live topics is painful.

- **Namespace:** `apicurio`
- **URL:** `apicurio.yanatech.co.uk`
- **Database:** CNPG (own database `apicurio`)
- **Auth:** Authentik OIDC
- **Manifest:** `apps/apicurio/argocd-app-apicurio.yaml`
- Define Avro schemas for: `forex.tick`, `forex.ohlcv`, `order.created`, `order.filled`, `order.cancelled`, `payment.initiated`, `payment.confirmed`

### 2.4 — Update Grafana
- Add Tempo as datasource (TraceQL queries)
- Add exemplar links between Prometheus metrics → Tempo traces
- Add Loki → Tempo trace correlation (via `traceId` in structured logs)
- Import/create dashboards: per-service RED metrics (Rate, Errors, Duration), Kafka consumer lag per topic

---

## Phase 3 — Microservice Platform
_Deploy before any production microservice goes live._

### 3.1 — KEDA (Kubernetes Event-driven Autoscaling)
- **Namespace:** `keda`
- **Helm chart:** `kedacore/keda`
- **Manifest:** `infrastructure/keda/argocd-app-keda.yaml`
- Primary scalers for your workloads:
  - `kafka` — scale consumers on topic lag (forex workers, order processors)
  - `prometheus` — scale on custom metrics (websocket connection count for forex real-time feed)
  - `cron` — scale to zero overnight for non-critical services
- Scale-to-zero for non-production services saves resource headroom

### 3.2 — Argo Rollouts
**Why before apps:** First microservice gets a `Rollout` resource from day one. No retrofitting.

- **Namespace:** `argo-rollouts`
- **Helm chart:** `argo/argo-rollouts`
- **Manifest:** `infrastructure/argo-rollouts/argocd-app-argo-rollouts.yaml`
- **Dashboard:** `rollouts.yanatech.co.uk` (Argo Rollouts UI)
- **Auth:** Authentik forward auth

Strategy per service type:
- **Forex real-time feed / order execution:** canary (5% → 20% → 50% → 100%, automated on Prometheus success rate)
- **E-commerce frontend:** blue-green (instant cutover, instant rollback)
- **Background workers:** canary (safe to run mixed versions briefly)
- **Payment service:** blue-green (no mixed versions ever)

### 3.3 — Kong (API Gateway)
- **Namespace:** `kong`
- **Helm chart:** `kong/kong`
- **URL:** `api.yanatech.co.uk`
- **Manifest:** `infrastructure/kong/argocd-app-kong.yaml`
- **Auth:** Authentik OIDC (JWT validation plugin)
- Sits between ingress-nginx and microservices
- Handles: rate limiting, request routing, API versioning (`/v1/`, `/v2/`), canary traffic weights (complements Argo Rollouts)
- ingress-nginx remains for non-API services (Nextcloud, Immich, Grafana, etc.)

### 3.4 — NetworkPolicy baselines
**Why now:** Before multi-tenant workloads land. Cilium enforces these natively.

Policy pattern per namespace:
```
default-deny-all ingress+egress
+ allow from ingress-nginx / kong
+ allow from monitoring (Prometheus scrape)
+ allow to CNPG (port 5432)
+ allow to Kafka (port 9092/9093)
+ allow to OTel Collector (port 4317)
+ service-specific rules (e.g. payment namespace: deny all cross-namespace except payment-gateway)
```

Payment service namespace gets the strictest policy — explicit allowlist only, no wildcards.

- **Manifest:** `infrastructure/network-policies/` (one file per namespace baseline)

### 3.5 — Hubble UI
- Cilium's traffic visibility UI — shows real-time service-to-service flows
- Enabled as part of Cilium (step 0.1) but surfaced here as a named endpoint
- **URL:** `hubble.yanatech.co.uk`
- **Auth:** Authentik forward auth
- Invaluable for debugging NetworkPolicy rules and verifying microservice communication patterns

---

## Phase 4 — First Applications
_Platform is complete. Build apps._

### 4.1 — yana-forex scaffold
Repo: `github.com/akann/yana-forex`

Services to plan (one ArgoCD app + one `Rollout` each):
- `forex-ingestion` — consumes real-time market data feed, publishes to Kafka `forex.tick`
- `forex-aggregator` — consumes `forex.tick`, produces `forex.ohlcv`, writes to TimescaleDB
- `forex-api` — REST/WebSocket API, serves real-time prices to frontend
- `forex-frontend` — Next.js UI
- `forex-risk` — position risk calculations, consumes order events

Database: CNPG cluster with TimescaleDB extension (`infrastructure/cnpg-clusters/`)
Kafka topics: `forex.tick`, `forex.ohlcv`, `forex.order`, `forex.execution`
Schemas: defined in Apicurio Registry before any service is written

### 4.2 — yana-ecommerce scaffold
Repo: `github.com/akann/yana-ecommerce`

Services:
- `store-api` — product catalogue, inventory
- `store-frontend` — Next.js storefront
- `order-service` — order creation, state machine
- `payment-service` — payment processing (isolated namespace, strict NetworkPolicy)
- `notification-service` — email/push via Kafka events + Gotify

Database: CNPG (own databases per service where practical — avoid shared DB between services)
Payment namespace: hardened NetworkPolicy, blue-green Rollout strategy only

### 4.3 — Docker Compose boundary
- **Local development only** — Compose on developer laptops for running services locally
- **Never on the cluster** — everything on k8s, even single-container services
- Each product repo includes a `docker-compose.dev.yml` that mirrors the k8s service graph locally (Postgres, Kafka, Redis/Valkey stubs)

---

## Complete Component Registry (post-plan)

### Infrastructure

| Component | Namespace | Helm Chart | Phase | Status |
|---|---|---|---|---|
| Cilium | kube-system | cilium/cilium | 0.1 | ✅ Live |
| MetalLB | metallb-system | metallb/metallb | existing | ✅ Live |
| ingress-nginx | ingress-nginx | ingress-nginx | existing | ✅ Live |
| cert-manager | cert-manager | jetstack/cert-manager | existing | ✅ Live |
| Reflector | kube-system | emberstack/reflector | existing | ✅ Live |
| Reloader | reloader | stakater/reloader | existing | ✅ Live |
| Kured | kured | kubereboot/kured | existing | ✅ Live |
| Descheduler | kube-system | descheduler/descheduler | existing | ✅ Live |
| Goldilocks | goldilocks | fairwinds-stable/goldilocks | existing | ✅ Live |
| ceph-csi-rbd | ceph-csi-rbd | ceph/ceph-csi-rbd | existing | ✅ Live |
| Harbor | harbor | harbor/harbor | 1.1 | ✅ Live |
| Actions Runner | actions-runner | gha-runner-scale-set-controller | 1.2 | ✅ Live |
| CNPG operator | cnpg-system | cnpg/cloudnative-pg | 1.3 | ✅ Live |
| CNPG clusters | cnpg-clusters | (CRDs) | 1.3 | ✅ Live |
| ESO | external-secrets | external-secrets/external-secrets | 1.5 | ✅ Live |
| Infisical | infisical | infisical-standalone | 1.5 | ✅ Live |
| Tempo | monitoring | grafana/tempo | 2.1 | Planned |
| OTel Collector | monitoring | open-telemetry/opentelemetry-collector | 2.2 | Planned |
| Apicurio Registry | apicurio | apicurio/apicurio-registry | 2.3 | Planned |
| KEDA | keda | kedacore/keda | 3.1 | Planned |
| Argo Rollouts | argo-rollouts | argo/argo-rollouts | 3.2 | Planned |
| Kong | kong | kong/kong | 3.3 | Planned |
| NetworkPolicies | per-namespace | (manifests) | 3.4 | Planned |

### Applications

| Service | Namespace | URL | Phase | Status |
|---|---|---|---|---|
| Vaultwarden | vaultwarden | vault.yanatech.co.uk | existing | ✅ Live (CNPG) |
| Authentik | authentik | authentik.yanatech.co.uk | existing | ✅ Live (CNPG) |
| Grafana | monitoring | grafana.yanatech.co.uk | existing | ✅ Live |
| ArgoCD | argocd | argocd.yanatech.co.uk | existing | ✅ Live |
| Kafka + UI | kafka | kafka-ui.yanatech.co.uk | existing | ✅ Live |
| Nextcloud | nextcloud | cloud.yanatech.co.uk | existing | ✅ Live (CNPG) |
| Immich | immich | photos.yanatech.co.uk | existing | ❌ Removed — pending fresh deploy |
| pgAdmin4 | pgadmin | pgadmin.yanatech.co.uk | existing | ✅ Live |
| Gotify | gotify | gotify.yanatech.co.uk | existing | ✅ Live |
| Headlamp | headlamp | headlamp.yanatech.co.uk | existing | ✅ Live (token auth) |
| Uptime Kuma | uptime-kuma | status.yanatech.co.uk | existing | ✅ Live |
| yanatech site | yanatech | www.yanatech.co.uk | existing | ✅ Live |
| Harbor | harbor | harbor.yanatech.co.uk | 1.1 | ✅ Live |
| Infisical | infisical | infisical.yanatech.co.uk | 1.5 | ✅ Live |
| Hubble UI | kube-system | hubble.yanatech.co.uk | 0.1 | ✅ Live |
| Argo Rollouts UI | argo-rollouts | rollouts.yanatech.co.uk | 3.2 | Planned |
| Kong API Gateway | kong | api.yanatech.co.uk | 3.3 | Planned |
| Apicurio | apicurio | apicurio.yanatech.co.uk | 2.3 | Planned |
| yana-forex | yana-forex | forex.yanatech.co.uk | 4.1 | Planned |
| yana-ecommerce | yana-ecommerce | store.yanatech.co.uk | 4.2 | Planned |

---

## Key Decisions & Rationale

| Decision | Rationale |
|---|---|
| Cilium native routing (not overlay) | Leverages existing OSPF mesh, zero encapsulation, sub-ms latency for forex |
| CNPG over pg1 VM | GitOps-managed, real streaming replication, PITR, Velero-coverable, eliminates manual VM |
| TimescaleDB in CNPG custom image | Stays in PostgreSQL ecosystem, CNPG manages it, avoids separate QuestDB deployment |
| ApplicationSet + sync waves over bootstrap.sh | Declarative, git-driven, no manual enumeration, correct ordering via waves |
| Argo Rollouts from day one | Retrofitting plain Deployments to Rollouts later is a full manifest rewrite |
| Kong alongside ingress-nginx | Kong for API microservices (rate limiting, versioning, JWT); ingress-nginx for non-API services |
| ESO + Infisical | Eliminates manual secret bootstrap, single source of truth, survives cluster rebuild |
| One ArgoCD app per microservice | Independent sync, rollback, and health status per service |
| Apicurio before first topic producer | Schema-first discipline; retrofitting schemas onto live topics is painful |
| Docker Compose for local dev only | Clean boundary: Compose = laptop, Kubernetes = everything on the cluster |

---

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Cilium migration loses pod connectivity | ✅ Resolved — one node at a time, verified after each |
| CNPG vchord/GLIBC issue blocks Immich | Immich removed. CNPG Bullseye uses GLIBC 2.31, vchord 1.1.1 needs 2.33. Fix: CNPG 1.29 Image Catalog or bookworm base image |
| pg1 decommission before all apps verified | ✅ Resolved — pg1 decommissioned after 3/4 migrations confirmed healthy |
| Headlamp token expiry | Set calendar reminder; automate renewal CronJob before 8760h expires |
| MetalLB IP exhaustion | ✅ Resolved — expanded to 50 IPs |
| Payment service data leak via pod-to-pod | Strict NetworkPolicy from day one (Phase 3.4); Cilium enforces, Hubble verifies |
| Schema incompatibility on Kafka topics | Apicurio compatibility mode `BACKWARD` enforced; producers must register schema before publishing |
| Infisical bundled ingress-nginx consuming MetalLB IP | ✅ Resolved — disabled via `ignoreDifferences` + manual deletion |
