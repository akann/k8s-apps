# cert-manager

TLS certificate automation via Let's Encrypt DNS-01 (Cloudflare). Installed via Helm, configured via CRDs in this directory.

## Helm Install

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace \
  --set crds.enabled=true
```

### Reflector (wildcard secret replication)

Reflector auto-replicates `wildcard-yanatech-tls` to all namespaces:

```bash
helm repo add emberstack https://emberstack.github.io/helm-charts
helm install reflector emberstack/reflector -n kube-system
```

## Apply Configuration

> **Prerequisites:** cert-manager and Reflector Helm releases must be installed first.

1. Create the Cloudflare API token secret (do **not** commit the real token):

   ```bash
   kubectl create secret generic cloudflare-api-token \
     --from-literal=api-token=<YOUR_TOKEN> \
     -n cert-manager
   ```

2. Apply the ClusterIssuer and Certificate:

   ```bash
   kubectl apply -f infrastructure/cert-manager/clusterissuer.yaml
   kubectl apply -f infrastructure/cert-manager/certificate.yaml
   ```

## Configuration

| Setting | Value |
|---------|-------|
| Issuer | `letsencrypt-prod` (ClusterIssuer) |
| Challenge | DNS-01 via Cloudflare |
| Cloudflare secret | `cloudflare-api-token` in `cert-manager` namespace |
| Wildcard cert | `wildcard-yanatech-tls` in `ingress-nginx` namespace |
| Covers | `yanatech.co.uk`, `*.yanatech.co.uk` |

Reflector replicates `wildcard-yanatech-tls` to all namespaces via the `reflection-auto-enabled` annotation on the Certificate's `secretTemplate`.
