# Headlamp

Modern, extensible Kubernetes web UI (CNCF / Kubernetes SIG UI) for browsing
all cluster resources — pods, logs, exec, events — across every namespace,
regardless of how they were deployed.

## Deployment

- **Managed by:** ArgoCD (`argocd-app-headlamp.yaml`)
- **Method:** upstream Helm chart, no local manifests
- **Chart repo:** https://kubernetes-sigs.github.io/headlamp/
- **Chart version:** `v0.42.0` (pinned — see Notes)
- **Namespace:** `headlamp`
- **URL:** https://headlamp.yanatech.co.uk

## Auth

Token-based (chart default). The chart creates a `headlamp` ServiceAccount bound
to cluster-admin via the `headlamp-admin` ClusterRoleBinding. To log in, generate
a token and paste it into the Headlamp login screen:

```bash
kubectl create token headlamp -n headlamp
```

> SSO via Authentik (OIDC) is planned — see the TODO in the main infra doc. When
> added, set `config.oidc.{clientID,clientSecret,issuerURL}` in the Helm values.

## Secrets

None required. (The chart creates an empty `oidc` Secret by default; it is unused
until OIDC is configured.)

## Notes

- **Pin the chart version.** Chart 0.40.1 introduced a `--session-ttl` flag that an
  older binary didn't recognize, causing CrashLoopBackOff. Always pin `targetRevision`
  and bump deliberately.
- **`hostUsers` OutOfSync.** On Kubernetes v1.32 the apiserver defaults
  `hostUsers: true` on the Deployment, which the chart doesn't template — producing a
  permanent (cosmetic) `OutOfSync`. Handled by an `ignoreDifferences` entry on
  `/spec/template/spec/hostUsers` in `argocd-app-headlamp.yaml`.
- Was originally installed via a manual `helm install`; migrated under ArgoCD on a
  `helm uninstall` + commit + apply.
