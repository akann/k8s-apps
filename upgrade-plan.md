# Homelab Upgrade & Expansion Plan
_Last updated: 2026-06-04_

## Context

3-node Proxmox cluster, 6-node Kubernetes, 48 vCPUs / 192GB RAM / 8.4TiB Ceph.
Current stable services: Vaultwarden, Authentik, Grafana/Loki, ArgoCD, Kafka, Nextcloud, Immich, pgAdmin4, Gotify, Headlamp, Uptime Kuma, Velero, Goldilocks, Descheduler, Kured, Reloader.
All databases on pg1 (VM 110, 192.168.22.40).

## Goals

- Replace pg1 with CloudNativePG (in-cluster, GitOps-managed, proper replication + PITR)
- Build a private platform for multiple production apps (forex trading, e-commerce, etc.)
- Each product in its own monorepo (e.g. `yana-forex`, `yana-ecommerce`); k8s manifests in `k8s-apps`
- CI/CD fully on-LAN: source repo → Actions Runner → Harbor → ArgoCD → cluster
- Replace Flannel with Cilium (native routing over existing OSPF mesh)
- Replace `bootstrap.sh` manual enumeration with ApplicationSet + sync waves
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

## Outstanding item from current state

- **Headlamp SSO** — blocked by upstream bug (Headlamp 0.42.0, GitHub issues #3884, #4789, #4876, #5025).
  Currently running with service account token (`8760h`). **Revisit on Headlamp 0.43.0+.**
  Token will expire — set a calendar reminder or automate renewal via CronJob before that happens.

- **Velero namespace list** — currently hardcoded `--include-namespaces`. Switch to
  `--exclude-namespaces` pattern so new apps are covered automatically without manual updates.

---

## Phase 0 — Foundation
_Nothing new is added until this phase is complete. Cluster must be quiet (weekend, Velero backup taken immediately before each step)._

### 0.1 — Cilium (replace Flannel)
**Why first:** CNI replacement is the most disruptive single operation. Must happen before any production workloads land.
**Mode:** Native routing (not overlay) — leverages existing OSPF mesh (25GbE, MTU 9000) for zero encapsulation overhead. Critical for forex latency requirements.

Steps:
- Take full Velero backup
- Deploy Cilium in parallel mode alongside Flannel (`cilium install --helm-set tunnel=disabled`)
- Cordon + drain one node at a time
- Remove Flannel CNI config and `cni0`/`flannel.1` interfaces per node after migration
- Verify pod-to-pod connectivity across nodes after each node
- Remove Flannel DaemonSet once all nodes migrated
- Enable Hubble (Cilium's traffic visibility) — `hubble.yanatech.co.uk`

Notes:
- kube-vip is CNI-independent — untouched
- MetalLB L2 advertisement continues to work with Cilium native routing
- Cilium replaces the need for Canal (NetworkPolicy enforcement is built in)

### 0.2 — Expand MetalLB pool
**Why now:** Quick config change. Current pool `192.168.22.200-220` (21 IPs) will be consumed by Harbor, CNPG read replicas, Kong, etc.
- Expand to `192.168.22.200-192.168.22.249` (50 IPs) — update pfSense NAT range accordingly
- Update `infrastructure/metallb/` manifests + apply

### 0.3 — ApplicationSet + sync waves (replace bootstrap.sh)
**Why now:** Fix the bootstrap mechanism before adding more apps to it.

Sync wave assignments:

| Wave | Apps |
|---|---|
| 0 | metallb, ceph-csi |
| 1 | cert-manager operator, cilium, ingress-nginx |
| 2 | cert-manager-config (ClusterIssuer) |
| 3 | reflector, reloader, kured, descheduler |
| 4 | authentik, monitoring (kube-prometheus-stack), velero |
| 5 | loki, promtail, uptime-kuma, headlamp, goldilocks |
| 6 | vaultwarden, kafka, argocd (self-managed) |
| 7 | All apps (nextcloud, immich, pgadmin, gotify, kafka-ui, yanatech) |
| 8 | New infrastructure (harbor, cnpg, eso, infisical, tempo, otel, keda, kong, argo-rollouts) |
| 9 | New apps (yana-forex, yana-ecommerce, etc.) |

Steps:
- Add `argocd.argoproj.io/sync-wave` annotation to every existing `argocd-app-*.yaml`
- Create `bootstrap/applicationset-infrastructure.yaml` and `bootstrap/applicationset-apps.yaml`
- Test ApplicationSet on live cluster (additive — won't fight existing apps if names match)
- Replace `bootstrap.sh` body with:
  ```bash
  kubectl apply -f bootstrap/applicationset-infrastructure.yaml
  kubectl apply -f bootstrap/applicationset-apps.yaml
  ```
- Update Velero schedule to use `--exclude-namespaces` instead of `--include-namespaces`

---

## Phase 1 — Platform Infrastructure
_Unblocks everything else. pg1 decommissioned by end of this phase._

### 1.1 — Harbor (private container registry)
**Why first:** Every subsequent step needs a private registry (CNPG custom image, CI pipeline, app images).

- **Namespace:** `harbor`
- **URL:** `harbor.yanatech.co.uk`
- **Helm chart:** `harbor/harbor`
- **Storage:** ceph-rbd PVCs for registry, chartmuseum, jobservice, database, redis, trivy
- **Database:** pg1 initially → migrate to CNPG in step 1.4
- **Auth:** Authentik OIDC
- **Manifest:** `infrastructure/harbor/argocd-app-harbor.yaml`

### 1.2 — Actions Runner Controller (CI on-LAN)
**Why here:** CI pipeline needed before CNPG custom image can be built and pushed.

- **Namespace:** `actions-runner`
- **Helm chart:** `actions-runner-controller/actions-runner-controller`
- **Runners:** one runner set per product repo (`yana-forex`, `yana-ecommerce`, `k8s-apps`)
- **Pushes to:** `harbor.yanatech.co.uk`
- **Manifest:** `infrastructure/actions-runner/argocd-app-actions-runner.yaml`

Pipeline pattern per product repo:
```yaml
# .github/workflows/build.yaml
- build image
- push to harbor.yanatech.co.uk/<repo>/<service>:<sha>
- update image tag in k8s-apps via git commit
- ArgoCD auto-syncs
```

### 1.3 — CloudNativePG operator + custom image
**Why here:** pg1 replacement. Harbor must exist first (custom image build).

**Custom CNPG image** (built in Harbor CI, stored at `harbor.yanatech.co.uk/infra/cnpg-custom:18`):
```dockerfile
FROM ghcr.io/cloudnative-pg/postgresql:18
USER root
RUN apt-get update && apt-get install -y postgresql-18-pgvector
COPY postgresql-18-vchord_1.1.1-1_amd64.deb /tmp/
RUN apt-get install -y /tmp/postgresql-18-vchord_1.1.1-1_amd64.deb
# Timescale for forex OHLCV/tick data
RUN apt-get install -y timescaledb-2-postgresql-18
USER postgres
```

**CNPG operator:**
- **Namespace:** `cnpg-system`
- **Helm chart:** `cnpg/cloudnative-pg`
- **Manifest:** `infrastructure/cnpg/argocd-app-cnpg.yaml`

**CNPG cluster** (`infrastructure/cnpg-clusters/`):
- 1 primary + 2 standbys (synchronous replication for payment/order critical DBs)
- Barman WAL archiving → Backblaze B2 `yanatech-cnpg` bucket (PITR)
- PgBouncer connection pooler enabled
- `infrastructure/cnpg-clusters/argocd-app-cnpg-clusters.yaml`

### 1.4 — Migrate all databases from pg1 to CNPG, decommission pg1

Migration order (lowest risk first):
1. pgAdmin4 (low risk, easy to verify)
2. Nextcloud
3. Immich (needs VectorChord — verify custom image first)
4. Authentik (pause selfHeal during migration)
5. Vaultwarden (last — highest criticality)

For each database:
- Pause ArgoCD selfHeal on the app
- `pg_dump` from pg1
- Restore to CNPG cluster
- Update secret pointing to CNPG service endpoint
- Verify app healthy
- Re-enable ArgoCD selfHeal

After all databases confirmed healthy on CNPG:
- Remove pg-backup.sh cron on pg1
- `ha-manager remove vm:110`
- `qm stop 110 && qm destroy 110`
- Remove pg1 section from `homelab-infrastructure.md`

Notes:
- Immich: `cube` and `earthdistance` extensions still require superuser pre-creation on CNPG cluster
- Vaultwarden: DATABASE_URL in `vaultwarden-secret` must be updated to CNPG service FQDN
- pgAdmin4: server connection in pgAdmin UI must be updated post-migration

### 1.5 — ESO (External Secrets Operator) + Infisical
**Why here:** Before apps multiply. Eliminates manual `kubectl create secret` on every rebuild.

- **ESO:** `infrastructure/eso/argocd-app-eso.yaml`
- **Infisical:** self-hosted, `infrastructure/infisical/argocd-app-infisical.yaml`, own CNPG database
- **Pattern:** all existing manual secrets become `ExternalSecret` CRDs in git; ESO pulls values from Infisical on sync
- **Bootstrap:** only manual step on fresh cluster = unlock Infisical (correct — unavoidable security boundary)
- Migrate existing secrets one namespace at a time after Infisical is stable

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
| Cilium | kube-system | cilium/cilium | 0.1 | Planned |
| MetalLB | metallb-system | metallb/metallb | existing | Live |
| ingress-nginx | ingress-nginx | ingress-nginx | existing | Live |
| cert-manager | cert-manager | jetstack/cert-manager | existing | Live |
| Reflector | kube-system | emberstack/reflector | existing | Live |
| Reloader | reloader | stakater/reloader | existing | Live |
| Kured | kured | kubereboot/kured | existing | Live |
| Descheduler | kube-system | descheduler/descheduler | existing | Live |
| Goldilocks | goldilocks | fairwinds-stable/goldilocks | existing | Live |
| ceph-csi-rbd | ceph-csi-rbd | ceph/ceph-csi-rbd | existing | Live |
| ApplicationSet | argocd | (built-in) | 0.3 | Planned |
| Harbor | harbor | harbor/harbor | 1.1 | Planned |
| Actions Runner | actions-runner | arc/actions-runner-controller | 1.2 | Planned |
| CNPG operator | cnpg-system | cnpg/cloudnative-pg | 1.3 | Planned |
| CNPG clusters | cnpg-clusters | (CRDs) | 1.3 | Planned |
| ESO | external-secrets | external-secrets/external-secrets | 1.5 | Planned |
| Infisical | infisical | infisical/infisical | 1.5 | Planned |
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
| Vaultwarden | vaultwarden | vault.yanatech.co.uk | existing | Live |
| Authentik | authentik | auth.yanatech.co.uk | existing | Live |
| Grafana | monitoring | grafana.yanatech.co.uk | existing | Live |
| ArgoCD | argocd | argocd.yanatech.co.uk | existing | Live |
| Kafka + UI | kafka | kafka-ui.yanatech.co.uk | existing | Live |
| Nextcloud | nextcloud | cloud.yanatech.co.uk | existing | Live |
| Immich | immich | photos.yanatech.co.uk | existing | Live |
| pgAdmin4 | pgadmin | pgadmin.yanatech.co.uk | existing | Live |
| Gotify | gotify | gotify.yanatech.co.uk | existing | Live |
| Headlamp | headlamp | headlamp.yanatech.co.uk | existing | Live (token auth) |
| Uptime Kuma | uptime-kuma | status.yanatech.co.uk | existing | Live |
| yanatech site | yanatech | www.yanatech.co.uk | existing | Live |
| Hubble UI | kube-system | hubble.yanatech.co.uk | 3.5 | Planned |
| Argo Rollouts UI | argo-rollouts | rollouts.yanatech.co.uk | 3.2 | Planned |
| Kong API Gateway | kong | api.yanatech.co.uk | 3.3 | Planned |
| Apicurio | apicurio | apicurio.yanatech.co.uk | 2.3 | Planned |
| Harbor | harbor | harbor.yanatech.co.uk | 1.1 | Planned |
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
| Cilium migration loses pod connectivity | One node at a time, verify after each; Velero backup before start |
| CNPG VectorChord image breaks Immich | Test custom image against Immich locally before cutover; pg1 stays live until confirmed |
| pg1 decommission before all apps verified | Hard rule: pg1 not destroyed until every app green on CNPG for 48h |
| Headlamp token expiry | Set calendar reminder; automate renewal CronJob before 8760h expires |
| MetalLB IP exhaustion | Expand pool in Phase 0.2 before it becomes a problem |
| Payment service data leak via pod-to-pod | Strict NetworkPolicy from day one (Phase 3.4); Cilium enforces, Hubble verifies |
| Schema incompatibility on Kafka topics | Apicurio compatibility mode `BACKWARD` enforced; producers must register schema before publishing |
