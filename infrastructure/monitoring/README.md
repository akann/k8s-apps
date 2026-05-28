# Monitoring

Prometheus + Grafana via `kube-prometheus-stack`. Installed via Helm using `values.yaml` in this directory.

## Helm Install

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f infrastructure/monitoring/values.yaml \
  --set grafana.adminPassword=<password>
```

## Upgrade

```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f infrastructure/monitoring/values.yaml
```

## Configuration

| Setting | Value |
|---------|-------|
| Namespace | `monitoring` |
| Grafana URL | https://grafana.yanatech.co.uk |
| Grafana storage | 10Gi, `ceph-rbd` |
| Prometheus retention | 30 days |
| Prometheus storage | 50Gi, `ceph-rbd` |
| Alertmanager storage | 10Gi, `ceph-rbd` |
| TLS | `wildcard-yanatech-tls` (Reflector-replicated) |

## Notes

- Grafana admin password is not stored here — pass `--set grafana.adminPassword=<password>` at install/upgrade time or store it in a Kubernetes secret beforehand.
- Authentik SSO integration for Grafana is pending (see homelab TODO list).
