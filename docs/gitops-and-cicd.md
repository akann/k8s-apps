# GitOps & CI/CD: From Git Push to Running Pod

Everything running on the cluster is defined in git and reconciled by ArgoCD — nothing gets `kubectl apply`'d by hand without a follow-up commit. This doc covers how a change actually makes it from a repo to a running workload, and the sharper edges hit building that pipeline.

## GitOps-first, one repo of record for cluster state

`k8s-apps` is the single source of truth for cluster state: every `Application` ArgoCD manages is defined here, even for apps whose actual source code and Kubernetes manifests live in their own separate repos (yana-stocks, shared-services, ml, dove-house-tt, akan). Those repos' manifests get pulled in by ArgoCD `Application` resources that point at the external repo and path — `k8s-apps` doesn't duplicate their YAML, it just declares "deploy this path from that repo."

Two smaller repos need this pattern's prerequisites explicitly set up: a git credential `Secret` in the `argocd` namespace (since they're private repos ArgoCD needs a token to clone) and, if their CI needs to push images to the in-cluster Harbor registry, a dedicated self-hosted GitHub Actions runner scale set — see below for why that second part matters.

## Sync waves: ordering a from-scratch bootstrap

A brand-new cluster can't have everything applied at once — Ceph CSI has to exist before anything can claim a PVC, cert-manager before anything can get a certificate, and so on. ArgoCD's sync-wave annotation orders this:

| Wave | What deploys |
|---|---|
| 0 | MetalLB, Ceph CSI |
| 1 | Cilium, cert-manager, ingress-nginx |
| 2 | MetalLB config, cert-manager config |
| 3 | Reflector, Reloader, Kured, Descheduler, KEDA, Argo Rollouts, NetworkPolicies |
| 4 | Authentik, monitoring stack, Tempo, Velero |
| 5 | Loki, Promtail, Headlamp, Goldilocks, Redis, MongoDB, MinIO, Kong |
| 6 | External Secrets Operator, Infisical, Redis-Insight, Mongo-Express |
| 7 | CNPG operator, then CNPG clusters |
| 8 | Harbor, Harbor's backup CronJob, the Actions Runner Controller |
| 9+ | Applications (Vaultwarden, Kafka, Immich, and the rest) |
| 10+ | yana-stocks microservices |

The pattern generally follows "infrastructure the rest depends on" → "infrastructure that provides secrets and databases" → "applications" — CNPG, for instance, has to come after Kong and MinIO (wave 5) since its clusters back up to MinIO and some of its consumers route through Kong.

## Why every private repo needs its own CI runner

`harbor.yanatech.co.uk`, the in-cluster container registry, isn't publicly resolvable — it only exists on the homelab's own network. GitHub-hosted runners (`ubuntu-latest`) therefore physically cannot push an image to it. Every repo that builds and pushes images gets its own self-hosted Actions Runner Controller scale set running inside the cluster, so the `docker build && docker push` step actually happens somewhere that can reach Harbor. Steps that don't need registry access (linting, type-checking, GitOps manifest validation) stay on GitHub-hosted runners, since there's no reason to burn homelab compute on those.

Each repo also gets its own Harbor *project* with its own project-scoped robot account, rather than sharing one set of push credentials across repos — a compromised or leaked credential for one project's CI can't be used to push to another project's images.

## ArgoCD conventions and its rougher edges

Standard `Application` manifests use `ServerSideApply=true` in `syncOptions` and `valuesObject:` (rather than a YAML-string `values:` block) for Helm values, to avoid indentation bugs. A few hard-won specifics:

- **Argo Rollouts requires server-side diffing globally, not just per-Application.** The Rollout CRD uses `x-kubernetes-preserve-unknown-fields`, so ArgoCD's default client-side diff fails with a schema error on it. Setting `ServerSideDiff=true` on the individual Application isn't enough on ArgoCD 3.x — the controller only honors it if the *global* `controller.diff.server.side` flag is also set at the Helm-values level for the ArgoCD installation itself.
- **CRDs whose controllers inject default fields need `ignoreDifferences`, and the right kind depends on how the controller writes those fields.** External Secrets Operator injects several default fields onto `ExternalSecret` objects it manages — those can be excluded with a `jqPathExpressions` ignore rule. CNPG's admission webhook similarly injects ~20 default spec fields onto `Cluster` objects, but `managedFieldsManagers`-based ignore rules don't work there, because CNPG's webhook uses a plain `Update` operation rather than `Apply`, so its injected fields aren't attributed to a named field manager ArgoCD can filter by.
- **A `Deployment` with both a static `replicas:` field and a KEDA `ScaledObject` will fight itself** unless the Application's `ignoreDifferences` also excludes `/spec/replicas` for that Deployment — otherwise every ArgoCD self-heal resets replica count to the static value, and KEDA immediately scales it back, producing visible pod churn on every sync.
- **All manifests for an app must live inside that Application's declared `source.path`.** Anything placed in a parent directory is silently ignored — there's no error, the file just never gets applied.
- **The `argocd.argoproj.io/refresh` annotation is a no-op if you set it to the same value it already has** — no watch event fires, so the app never actually re-syncs. Alternating the value (or removing and re-adding the annotation) is needed to force a refresh.
- **No git webhooks are configured for these repos** — ArgoCD relies on polling plus its own local clone cache in `argocd-repo-server`. That cache can occasionally go stale even after a `refresh: hard`, recognizable by suspiciously fast controller sync times (a cache hit rather than a real fetch); restarting `argocd-repo-server` clears it.

## Known, accepted "OutOfSync"

A handful of Applications show as `OutOfSync` permanently despite being fully `Healthy`, for reasons specific to how their CRDs or OCI charts report state (a registry-limitation on the runner controller, cluster-scoped CRDs ArgoCD tracks twice, a bundled Helm chart that mutates its own values, and a cosmetic diff left behind by a field-manager migration on one Rollout). These are deliberately left as-is rather than "fixed" — chasing them to `Synced` would mean fighting the tooling instead of the actual cluster state.
