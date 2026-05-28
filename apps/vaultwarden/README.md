# Vaultwarden

## Manual prerequisite

Before syncing, create the secret in the `vaultwarden` namespace.
Store all values in Vaultwarden itself once it's up, and in a secure location during bootstrap.

```bash
kubectl create namespace vaultwarden

kubectl create secret generic vaultwarden-secret \
  --from-literal=DATABASE_URL='postgresql://vaultwarden:<password>@authentik-postgresql.authentik.svc.cluster.local:5432/vaultwarden' \
  --from-literal=ADMIN_TOKEN='<generate with: openssl rand -base64 48>' \
  --from-literal=DOMAIN='https://vault.yanatech.co.uk' \
  --from-literal=SIGNUPS_ALLOWED='false' \
  -n vaultwarden
```

## Notes
- Database: Authentik PostgreSQL instance (authentik namespace)
- `SIGNUPS_ALLOWED=false` — create your account first via ADMIN_TOKEN, then disable admin access
- When dedicated PostgreSQL VM is ready, migrate database and update DATABASE_URL

## TODO
- Migrate to dedicated PostgreSQL VM
- Move secrets to Sealed Secrets
