# Vaultwarden

Password manager (Bitwarden-compatible). Deployed via ArgoCD.

## Secrets

Managed by ESO — ExternalSecret `vaultwarden-secret` pulls from Infisical:

| Infisical key | Secret key | Description |
|---|---|---|
| `/vaultwarden/DATABASE_URL` | `DATABASE_URL` | `postgresql://vaultwarden:<pw>@pg-main-rw.cnpg-clusters.svc.cluster.local:5432/vaultwarden` |
| `/vaultwarden/ADMIN_TOKEN` | `ADMIN_TOKEN` | bcrypt hash of the admin password |
| `/vaultwarden/DOMAIN` | `DOMAIN` | `https://vault.yanatech.co.uk` |
| `/vaultwarden/SIGNUPS_ALLOWED` | `SIGNUPS_ALLOWED` | `false` |

Store the raw values in Vaultwarden itself as the bootstrap source of truth.

## Database

Shared CNPG cluster `pg-main` in the `cnpg-clusters` namespace.  
Connection: `pg-main-rw.cnpg-clusters.svc.cluster.local:5432`, database `vaultwarden`, owner `vaultwarden`.

## Notes
- `SIGNUPS_ALLOWED=false` — create your account first via the admin panel (`/admin`), then revoke the admin token
- Data volume: `vaultwarden-data` PVC (5 Gi, ceph-rbd) — mounted at `/data`
- Reloader annotation on the Deployment restarts pods automatically when `vaultwarden-secret` changes
