# ArgoCD App-of-Apps Bootstrap

## Fresh cluster bootstrap order

1. Install ArgoCD
2. Apply manual prerequisites (secrets):
   - `csi-rbd-secret` in `ceph-csi-rbd`
   - `cloudflare-api-token` in `cert-manager`
   - `grafana-authentik-secret` in `monitoring`
   - `authentik-secret` in `authentik`
   - `vaultwarden-secret` in `vaultwarden`
3. Apply the root app:
   ```bash
   kubectl apply -f argocd/root-app.yaml
   ```
4. ArgoCD will deploy everything else automatically.

## Structure

```
argocd/
├── root-app.yaml           # Apply this once — bootstraps everything
├── infrastructure-apps.yaml  # Picks up all argocd-app-*.yaml in infrastructure/
└── apps-apps.yaml            # Picks up all argocd-app-*.yaml in apps/
```

## Adding a new app

1. Create manifests in `apps/<appname>/` or `infrastructure/<appname>/`
2. Add an `argocd-app-<appname>.yaml` in the same directory
3. Push to git — ArgoCD picks it up automatically
