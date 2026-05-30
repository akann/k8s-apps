# Headlamp
Kubernetes web UI for browsing cluster resources — pods, logs, exec, events — across all namespaces.
## Deployment
- ArgoCD-managed via upstream Helm chart (no local manifests)
- Chart repo: https://kubernetes-sigs.github.io/headlamp/
- Chart version: v0.42.0 (pinned)
- Namespace: headlamp
- URL: https://headlamp.yanatech.co.uk

No manual prerequisites — no secret required.
## Access
Token-based login. The chart's `headlamp` ServiceAccount is bound to cluster-admin via the `headlamp-admin` ClusterRoleBinding. Generate a login token and paste it into the Headlamp login screen:
```bash
kubectl create token headlamp -n headlamp
```
## Notes
- Pin the chart version — 0.40.1 added a `--session-ttl` flag that crashed older binaries (CrashLoopBackOff).
- `hostUsers: true` is apiserver-defaulted on v1.32 and not templated by the chart, causing a permanent cosmetic OutOfSync. Handled by `ignoreDifferences` on `/spec/template/spec/hostUsers` in `argocd-app-headlamp.yaml`.
- SSO via Authentik (OIDC) planned — set `config.oidc.{clientID,clientSecret,issuerURL}` in the Helm values when added.
- Migrated from a manual `helm install` to ArgoCD.
