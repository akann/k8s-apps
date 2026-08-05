# Velero

Cluster backups to Backblaze B2.

## Credentials

Managed by ESO — ExternalSecret `velero-b2-credentials` pulls from Infisical:
- `/velero/aws_access_key_id`
- `/velero/aws_secret_access_key`

Store the raw credentials in Vaultwarden as the bootstrap source of truth.

## Backup schedule
- Weekly, Sundays at 02:00 UTC (`0 2 * * 0`)
- Retention: 30 days (720h)
- Scope: all namespaces except system/operator namespaces (see `excludedNamespaces` in `argocd-app-velero.yaml`)

## Manual backup
```bash
velero backup create manual-backup --include-namespaces vaultwarden,authentik
```

## Restore
```bash
velero backup get
velero restore create --from-backup <backup-name>
```

## Storage
- Bucket: yanatech-velero
- Endpoint: s3.eu-central-003.backblazeb2.com
- Region: eu-central-003

## Monitoring

`argocd-app-velero.yaml` sources the upstream Helm chart directly (not this
directory), so files that live here alongside it — `external-secret.yaml`,
`service-monitor.yaml` — are **not** synced by anything and must be applied
manually after committing:

```bash
kubectl apply -f infrastructure/velero/service-monitor.yaml
```

`service-monitor.yaml` scrapes Velero's own `/metrics` (port 8085, already
exposed by the chart). `infrastructure/monitoring/rules/prometheusrule-velero.yaml`
(synced continuously via the monitoring stack's rules child-app) alerts on
`velero_backup_failure_total`/`velero_backup_partial_failure_total` increases
and on the exporter itself going down.
