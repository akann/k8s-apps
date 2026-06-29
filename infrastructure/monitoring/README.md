# Monitoring

kube-prometheus-stack v72.6.2 (Grafana 12.0.0) deployed via ArgoCD Helm Application.

## Deployment

Managed by ArgoCD — the canonical config is `infrastructure/monitoring/argocd-app-monitoring.yaml`. Do not run `helm install/upgrade` manually.

```bash
# Trigger a re-sync if needed
argocd app sync monitoring --grpc-web
```

## Configuration

| Setting | Value |
|---------|-------|
| Namespace | `monitoring` |
| Chart | `prometheus-community/kube-prometheus-stack` `72.6.2` |
| Grafana URL | https://grafana.yanatech.co.uk |
| Grafana version | 12.0.0 |
| Grafana auth | Authentik OIDC (`GF_AUTH_GENERIC_OAUTH_*` env vars) |
| Grafana storage | 10 Gi, `ceph-rbd` |
| Prometheus retention | 30 days |
| Prometheus storage | 50 Gi, `ceph-rbd` |
| Alertmanager storage | 10 Gi, `ceph-rbd` |
| TLS | `wildcard-yanatech-tls` (Reflector-replicated) |

## Grafana Datasources

| Datasource | Type | Endpoint |
|------------|------|----------|
| Prometheus | prometheus | in-namespace, port 9090 |
| Loki | loki | `loki.monitoring.svc.cluster.local:3100` |
| Tempo | tempo | `tempo.monitoring.svc.cluster.local:3200` |
| Alertmanager | alertmanager | `kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local:9093` |
| Infinity | yesoreyeram-infinity-datasource | external REST/JSON/CSV |
| PostgreSQL (auth-service) | postgres | `auth-service-pg-rw.yana-stocks.svc.cluster.local:5432` |

## Grafana Plugins

- `yesoreyeram-infinity-datasource` (Infinity) — declared in Helm values, auto-installed on pod start

## Alertmanager Routing

| Receiver | Trigger | Channel |
|----------|---------|---------|
| `null` | `Watchdog`, `InfoInhibitor` | discarded |
| `gotify` | all other alerts (default) | Gotify push (`alertmanager-gotify-bridge`) |
| `critical-alerts` | `severity=critical` | Gotify push (`alertmanager-gotify-bridge`) |

All alerts route to Gotify only. Email notifications were removed 2026-06-29.

## Secrets

Two secrets are required before the Grafana pod starts:

| Secret | Managed by | Contents |
|--------|-----------|---------|
| `grafana-authentik-secret` | ESO (Infisical) | `client_id`, `client_secret` |
| `grafana-pg-secret` | ESO (Kubernetes provider → yana-stocks) | `password` (CNPG auth-service-pg) |

PostgreSQL password is synced from the `auth-service-pg-app` secret in the `yana-stocks` namespace via a Kubernetes-provider ClusterSecretStore (`k8s-yana-stocks`).

Note: `grafana-smtp-secret` and `external-secret-smtp.yaml` still exist in the cluster but are no longer referenced by Alertmanager.

## Files in This Directory

Files in `infrastructure/monitoring/` are **not continuously managed** by any running ArgoCD Application after the initial bootstrap — the `monitoring` app converted itself to a Helm source. New files added here must be applied manually:

```bash
kubectl apply -f infrastructure/monitoring/<file>.yaml
```

| File | Purpose |
|------|---------|
| `argocd-app-monitoring.yaml` | ArgoCD Application (Helm chart + full values) |
| `argocd-app-monitoring-rules.yaml` | ArgoCD child app for PrometheusRule CRDs |
| `argocd-app-grafana-dashboards.yaml` | ArgoCD child app for Grafana dashboards |
| `external-secret-smtp.yaml` | ESO ExternalSecret → `grafana-smtp-secret` |
| `external-secret-pg.yaml` | ESO ExternalSecret → `grafana-pg-secret` |
| `eso-k8s-pg-rbac.yaml` | ServiceAccount + ClusterRole/Binding for k8s-yana-stocks store |
| `eso-k8s-pg-store.yaml` | ClusterSecretStore `k8s-yana-stocks` (Kubernetes provider) |

## Network Policy Notes

- Grafana → Prometheus: `CiliumNetworkPolicy` required (`ciliumnetpol-grafana-prometheus.yaml`) — standard NetworkPolicy ClusterIP routing fails in Cilium native routing mode
- Grafana → PostgreSQL (yana-stocks): `CiliumNetworkPolicy` required (`ciliumnetpol-grafana-pg.yaml`) — same reason
- Alertmanager → Gotify: standard NetworkPolicy sufficient (`allow-alertmanager-egress`)

## ArgoCD Metrics Scraping

The ArgoCD application controller exposes `argocd_app_info` on port 8082. Prometheus scrapes it via a `ServiceMonitor` created by the ArgoCD Helm chart.

**Enabled in `infrastructure/argocd/values.yaml`:**
```yaml
controller:
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
      additionalLabels:
        release: kube-prometheus-stack
```

The `additionalLabels: {release: kube-prometheus-stack}` is required for the kube-prometheus-stack Prometheus operator to discover the ServiceMonitor.

**PrometheusRules:** `infrastructure/monitoring/rules/prometheusrule-argocd.yaml` defines three alerts (all route to Gotify via Alertmanager):

| Alert | Condition | Severity | For |
|-------|-----------|----------|-----|
| `ArgoCDAppDegraded` | `health_status="Degraded"` | critical | 5m |
| `ArgoCDAppMissing` | `health_status="Missing"` | critical | 5m |
| `ArgoCDAppOutOfSync` | `sync_status="OutOfSync"` | warning | 15m |

Note: Apps listed in the README.md "Known Permanent OutOfSync" section will fire `ArgoCDAppOutOfSync` continuously. Silence them in Alertmanager or add `unless` matchers to the rule if needed.
