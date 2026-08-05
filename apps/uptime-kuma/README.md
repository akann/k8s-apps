# Uptime Kuma

`https://status.yanatech.co.uk` — external uptime monitoring, alerting via the
Gotify notification configured in its UI (id 1, reused by the meta-monitoring
push heartbeat too — see `infrastructure/monitoring/README.md`).

## Monitor configuration is not in git

Monitors, notifications, and everything else live in uptime-kuma's own SQLite
DB (`/app/data/kuma.db` in the pod's PVC), managed entirely through its web
UI/socket.io API — there is no CRD or declarative config to commit. This list
is the source of truth for what's *intended* to be monitored; check it
against the live UI periodically, since drift here is otherwise invisible.

## Intended monitor coverage

| Monitor | Type | Target |
|---|---|---|
| yana-stocks frontend | http | https://stocks.yanatech.co.uk |
| yana-stocks API (market) | http | https://api-gateway.yanatech.co.uk/api/market/movers |
| Immich | http | https://photos.yanatech.co.uk |
| Nextcloud | http | https://cloud.yanatech.co.uk |
| Vaultwarden | http | https://vault.yanatech.co.uk |
| yanatech.co.uk | http | http://yanatech.yanatech.svc.cluster.local:3000 (in-cluster) |
| ArgoCD | http | https://argocd.yanatech.co.uk |
| Harbor | http | https://harbor.yanatech.co.uk |
| Infisical | http | https://infisical.yanatech.co.uk |
| Authentik | http | https://authentik.yanatech.co.uk |
| Kafka | port | kafka-cluster-kafka-bootstrap.kafka.svc.cluster.local |
| MongoDB | port | mongodb-headless.mongodb.svc.cluster.local |
| Redis | port | redis-master.redis.svc.cluster.local |
| PostgreSQL (pg-main) | port | pg-main-rw.cnpg-clusters.svc.cluster.local |
| PostgreSQL (auth-service-pg) | port | auth-service-pg-rw.yana-stocks.svc.cluster.local |
| akan personal site | http | https://akan.nkweini.org |
| dovehousett.org | http | https://dovehousett.org |
| stg.dovehousett.org | http | https://stg.dovehousett.org |
| Grafana | http | https://grafana.yanatech.co.uk |
| shared-api-docs | http | https://shared-api-docs.yanatech.co.uk (Authentik-gated — monitor checks reachability, not authenticated content) |
| ops-agent (ml) | http | https://ml.yanatech.co.uk/ops-agent/ (Authentik-gated — same caveat) |
| Lighthouse CI | http | https://lighthouse.yanatech.co.uk (HTTP Basic Auth configured on the monitor itself, credentials from Infisical `/lighthouse-ci/BASIC_AUTH_*`) |

All rows confirmed present and reporting `Up` as of 2026-08-05 (the last 7 were
added that day — previously missing, audited via the live DB).

## Meta-monitoring push heartbeat

A dedicated Push-type monitor ("Prometheus/Alertmanager Heartbeat", created
2026-08-05) also lives here — it's the receiving end of the Watchdog
dead-man's-switch described in `infrastructure/monitoring/README.md`, not a
normal target check. Not listed in the table above since it isn't checking an
external target. If it's ever deleted/recreated, `argocd-app-monitoring.yaml`'s
`uptime-kuma-heartbeat` receiver needs the new push token.
