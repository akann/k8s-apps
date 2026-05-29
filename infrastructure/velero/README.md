# Velero

Cluster backups to Backblaze B2.

## Manual prerequisite

```bash
kubectl create namespace velero

kubectl create secret generic velero-b2-credentials \
  --from-literal=cloud="[default]
aws_access_key_id=<keyID>
aws_secret_access_key=<applicationKey>" \
  -n velero
```

Store credentials in Vaultwarden.

## Backup schedule
- Daily at 2am UTC
- Retention: 30 days (720h)
- Namespaces: vaultwarden, authentik, monitoring, kafka, ingress-nginx, cert-manager, argocd

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
