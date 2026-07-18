# Disaster Recovery Runbook

How to rebuild this cluster from nothing but git and Backblaze B2. Written after a full audit and a real, verified restore test (2026-07-18) — see "What's actually been tested" at the end before trusting any single step blindly.

## Scope: two different disasters

This runbook covers two distinct scenarios, and they require very different amounts of work:

- **A) Kubernetes nodes lost, Ceph/Proxmox survives.** The common case — a bad `kubeadm` upgrade, lost control-plane quorum, or VMs that need recreating. Ceph RBD volumes and their data are untouched. Once the k8s cluster and CNI are back, existing PVCs reattach with their data intact — **no CNPG recovery is needed**, just re-running the bootstrap sequence (Phase 1-3 below). Skip Phase 4.
- **B) Total loss, including Ceph.** pve1-3 gone, or Ceph pools destroyed. Every PVC's data is gone. Kubernetes itself needs rebuilding (kubeadm — see `proxmox-cluster-setup.md`/`pve-node-operations.md`, not covered here), and every CNPG database needs a real recovery from Backblaze B2 (Phase 4).

If you're not sure which scenario you're in: check `kubectl get pv` (or equivalent) — if old Ceph RBD volumes are still bindable, you're in scenario A.

## Prerequisites

1. A working Kubernetes cluster (kubeadm, CNI not yet installed) — out of scope here, see `proxmox-cluster-setup.md`.
2. `kubectl` and `helm` against that cluster.
3. Access to Vaultwarden (`vault.yanatech.co.uk`) for the manual secrets below. **If Vaultwarden itself is down** (its data lives in `pg-main`, recoverable per Phase 4, but that's circular — you need some of these secrets to get ESO/Infisical running before you can even reach the point of restoring `pg-main`): you need an out-of-band copy of at least the secrets marked mandatory below. If no such copy exists, that's a gap — fix it before you need this runbook for real.
4. A local clone of `github.com/akann/k8s-apps` at the revision you want to deploy (normally `main`).

## Phase 1 — Manual secrets (before running `bootstrap.sh`)

These are not ESO-managed and must exist before the relevant wave runs. All values come from Vaultwarden unless noted.

```bash
# ceph-csi-rbd namespace
kubectl create secret generic csi-rbd-secret -n ceph-csi-rbd \
  --from-literal=userID=kubernetes \
  --from-literal=userKey=<Vaultwarden: ceph-csi-rbd>

# cert-manager namespace
kubectl create secret generic cloudflare-api-token -n cert-manager \
  --from-literal=api-token=<Vaultwarden: cloudflare-api-token>

# monitoring namespace
kubectl create secret generic grafana-authentik-secret -n monitoring \
  --from-literal=client_id=<id> \
  --from-literal=client_secret=<Vaultwarden: grafana-authentik>

# authentik namespace — all 7 keys required (confirmed live 2026-07-18)
kubectl create secret generic authentik-secret -n authentik \
  --from-literal=AUTHENTIK_SECRET_KEY=<key> \
  --from-literal=AUTHENTIK_POSTGRESQL__HOST=<host> \
  --from-literal=AUTHENTIK_POSTGRESQL__NAME=<db name> \
  --from-literal=AUTHENTIK_POSTGRESQL__USER=<db user> \
  --from-literal=AUTHENTIK_POSTGRESQL__PASSWORD=<password> \
  --from-literal=AUTHENTIK_REDIS__HOST=<redis host> \
  --from-literal=AUTHENTIK_EMAIL__PASSWORD=<email password>

# external-secrets namespace — THE MOST LOAD-BEARING SECRET IN THIS LIST.
# Name MUST be infisical-eso-credentials (matches
# infrastructure/eso/cluster-secret-store.yaml). Get this wrong and ESO can
# never authenticate to Infisical, which cascades to every other
# ExternalSecret in the cluster failing to sync. (bootstrap.sh previously
# documented the wrong name here — fixed 2026-07-18.)
kubectl create namespace external-secrets
kubectl create secret generic infisical-eso-credentials -n external-secrets \
  --from-literal=clientId=1a5f2d02-e826-4132-9784-aa8e23094416 \
  --from-literal=clientSecret=<Vaultwarden: eso-k8s-machine-identity>

# Private-repo git credentials, in the argocd namespace (created AFTER ArgoCD
# is installed in Phase 2 — argocd namespace doesn't exist yet before that).
# Same repository-Secret shape for all four:
for repo in akan shared-services ml dove-house-tt; do
  kubectl create secret generic repo-$repo -n argocd \
    --from-literal=type=git \
    --from-literal=url=https://github.com/akann/$repo \
    --from-literal=username=<user> \
    --from-literal=password=<Vaultwarden: repo-$repo>
  kubectl label secret repo-$repo -n argocd argocd.argoproj.io/secret-type=repository
done

# dove-house-tt + dove-house-tt-stg namespaces — ghcr.io pull secret
# (images are private; create in BOTH namespaces, Secrets don't cross)
for ns in dove-house-tt dove-house-tt-stg; do
  kubectl create secret docker-registry ghcr-secret -n $ns \
    --docker-server=ghcr.io \
    --docker-username=<user> \
    --docker-password=<Vaultwarden: ghcr-pull-token>
done
```

Also create the Infisical folders/secrets that ESO expects to already exist (see `bootstrap.sh`'s header comment for the current list — `redis`, `mongodb` folders, etc.).

## Phase 2 — Run `bootstrap.sh`

```bash
cd k8s-apps
./bootstrap.sh
```

This installs ArgoCD, then applies every `argocd-app-*.yaml` in wave order (mirrors `kustomization.yaml` exactly as of 2026-07-18 — verify that's still true if it's been a while: `diff <(grep -oP '(?<=- )(infrastructure|apps)/\S+\.yaml' kustomization.yaml) <(grep -oP '(?<=kubectl apply -f )(infrastructure|apps)/\S+\.yaml' bootstrap.sh | sort -u)` should be empty modulo ordering).

Stop and do these manually when the script tells you to:

1. **After ESO + Infisical (wave 6):** wait for both healthy, add the `eso-k8s` machine identity to the Infisical project members list in the Infisical UI (not just org-level), then confirm secrets are flowing: `kubectl get externalsecret -A` — nothing should stay `NotReady` for more than a minute or two once this step is done.
2. **ArgoCD dex secret** (needs the `argocd` namespace to exist first): `kubectl -n argocd patch secret argocd-secret -p '{"stringData":{"dex.authentik.clientSecret":"<Vaultwarden: argocd-dex>"}}'`
3. **Infisical ingress** — the bundled nginx is disabled by design; the script's own commands patch it to use the `nginx` ingress class and set the webhook's `failurePolicy` to `Ignore`. If ingress/ExternalSecret creation starts failing cluster-wide at any point, that webhook is almost certainly the cause — `kubectl delete validatingwebhookconfiguration infisical-ingress-nginx-admission`.
4. **Headlamp SSO is broken upstream** — issue a token manually: `kubectl create token headlamp -n headlamp --duration=8760h`
5. **Immich**: set up the admin account at `https://photos.yanatech.co.uk`, then configure Authentik SSO under Administration → Settings → OAuth.
6. **Authentik outposts**: Mongo Express and RedisInsight both need their forward-auth outpost configured in the Authentik UI (see `CLAUDE.md`'s SSO section for the general pattern).

## Phase 3 — Verify the sync

```bash
argocd app list | grep -v "Synced.*Healthy"
```

Expect this to be non-empty for a few minutes on a fresh bootstrap — apps sync in wave order and some (`yana-stocks` especially, ~70 resources) take a couple of minutes even once ArgoCD has already picked up the right revision. Re-run until it settles. A handful of *permanently* `OutOfSync`-but-`Healthy` apps are expected and documented in `CLAUDE.md` (`actions-runner-controller`, `argo-rollouts`, `infisical`, the `yana-stocks`/`ml-predictor` Rollout) — don't chase those.

If an app is stuck `OutOfSync` with no sync operation running, the `argocd-repo-server`'s local git clone cache may be stale: `kubectl rollout restart deployment argocd-repo-server -n argocd`, then refresh the app again.

## Phase 4 — CNPG database recovery (scenario B only)

**Skip this entirely if Ceph survived** — existing PVCs just reattach with their data, and the clusters in `bootstrap.sh`/`kustomization.yaml` come up via their normal `bootstrap.initdb` path pointing at already-populated volumes. This phase is only for genuine data loss.

### Per-cluster reference

All 6 backed-up clusters share one B2 bucket (`yanatech-cnpg`, `s3.eu-central-003.backblazeb2.com`) and one shared credential path (Infisical `/cnpg-clusters/ACCESS_KEY_ID` + `ACCESS_SECRET_KEY`, synced into each namespace as `cnpg-b2-credentials` — this ExternalSecret is already part of each app's manifests, so it'll exist once Phase 2/3 finish).

| Cluster | Namespace | B2 path |
|---|---|---|
| `pg-main` | `cnpg-clusters` | `s3://yanatech-cnpg/pg-main` |
| `immich-postgres` | `immich` | `s3://yanatech-cnpg/immich-postgres` |
| `auth-service-pg` | `yana-stocks` | `s3://yanatech-cnpg/auth-service-pg` |
| `k8s-docs-pg` | `k8s-docs` | `s3://yanatech-cnpg/k8s-docs-pg` |
| `dove-house-tt-pg` | `dove-house-tt` | `s3://yanatech-cnpg/dove-house-tt-pg` |
| `ops-agent-pg` | `ops-agent` | `s3://yanatech-cnpg/ops-agent-pg` |

`dove-house-tt-stg-pg` has no backup by design (disposable staging data) — just let it re-`initdb` empty and reseed manually.

### ⚠️ Critical: disable ArgoCD self-heal for the app first

The Cluster manifests in git use `bootstrap.initdb`, not `bootstrap.recovery` — that's correct for steady-state, but if you edit the *live* Cluster object to add a recovery bootstrap without also stopping ArgoCD from reconciling it, **selfHeal will revert your recovery attempt back to the git-tracked initdb version mid-restore**. Before touching a Cluster for recovery:

```bash
kubectl patch application <owning-app> -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
```

Re-enable automated sync (`{"automated":{"prune":true,"selfHeal":true}}`) once the cluster is confirmed healthy and you've either reverted the live object back to a normal state or updated git to match.

### Recovery procedure

If the original Cluster object still exists but its PVC/data is gone, delete it first (`kubectl delete cluster <name> -n <namespace>` — this does not touch the B2 backup data, only the live k8s objects). Then apply a recovery version:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-main          # match the ORIGINAL name exactly if possible
  namespace: cnpg-clusters
spec:
  instances: 1            # scale up to the normal instance count once healthy
  imageName: <same image the original cluster used>
  storage:
    size: <same size>
    storageClass: ceph-rbd
  bootstrap:
    recovery:
      source: <same as metadata.name above>   # see gotcha below
  externalClusters:
    - name: <must match bootstrap.recovery.source above>
      barmanObjectStore:
        # serverName only needed if externalClusters[].name differs from the
        # ORIGINAL cluster's own name — CNPG defaults to looking for the
        # backup under <destinationPath>/<externalClusters[].name>/, which is
        # only correct if that name matches what the original cluster
        # actually archived under. Hit this exact bug during testing
        # (2026-07-18): naming the entry "pg-main-source" and omitting
        # serverName made it look under a path that never existed
        # ("no target backup found") even though the real backup was right
        # there under the original name.
        serverName: pg-main
        destinationPath: s3://yanatech-cnpg/pg-main
        endpointURL: https://s3.eu-central-003.backblazeb2.com
        s3Credentials:
          accessKeyId:
            name: cnpg-b2-credentials
            key: ACCESS_KEY_ID
          secretAccessKey:
            name: cnpg-b2-credentials
            key: ACCESS_SECRET_KEY
        wal:
          compression: gzip
        data:
          compression: gzip
  # keep the cluster's normal `backup:` block from the git-tracked manifest
  # too, so it resumes archiving to B2 once recovered
```

Swap `pg-main`/`cnpg-clusters` for the target cluster/namespace and its B2 path from the table above. Watch it:

```bash
kubectl get cluster <name> -n <namespace> -w
```

until `status.phase` reads `Cluster in healthy state`. Then verify actual data, not just that the pod started:

```bash
kubectl exec -n <namespace> <name>-1 -c postgres -- psql -U postgres -l
kubectl exec -n <namespace> <name>-1 -c postgres -- psql -U postgres -d <dbname> -c '\dt'
```

`pg_stat_user_tables.n_live_tup` will read 0 immediately after recovery (stale autovacuum stats on a freshly recovered DB, not a real signal) — use `SELECT count(*) FROM <table>` for ground truth.

Once confirmed healthy with real data: scale `instances` back up to the original count, restore the manifest to its normal git-tracked `bootstrap.initdb` form (bootstrap is only consulted at creation time, so this is just for git cleanliness — it won't re-trigger), re-enable ArgoCD automated sync, and commit.

## Verification checklist

- `argocd app list | grep -v "Synced.*Healthy"` → empty (or only the documented permanent exceptions)
- `kubectl get externalsecret -A` → all `SecretSynced: True`
- `kubectl get cluster -A` → all `status.phase: Cluster in healthy state`
- Spot-check a few app URLs from the Services table in `CLAUDE.md`
- A day later: `kubectl get backup -n <namespace>` for each recovered cluster shows a fresh `completed` entry — confirms it resumed archiving, not just that recovery worked once

## What's actually been tested

- **CNPG recovery mechanism**: tested end-to-end for real (2026-07-18) — recovered `ops-agent-pg` from B2 into a throwaway namespace with zero shortcuts, verified exact row-count parity against the live source (4810/4640/11110/10 rows across all 4 tables), then fully cleaned up. This validates the recovery YAML shape and the `serverName` gotcha above are correct.
- **`bootstrap.sh`'s manual secrets**: every one audited against live cluster state on 2026-07-18. One was wrong (`infisical-eso-credentials`, fixed) and one was incomplete (`authentik-secret`'s key list, fixed). The rest confirmed correct.
- **`bootstrap.sh` vs. `kustomization.yaml` drift**: fixed and diff-verified 2026-07-18.
- **NOT tested**: a real cold-start `kubeadm` + `bootstrap.sh` run against a genuinely empty cluster, start to finish, in one sitting. Everything above was verified against pieces of the live cluster or in an isolated throwaway namespace — not a full simulated disaster. Treat this runbook as strong evidence, not a guarantee, and re-verify the `bootstrap.sh`/`kustomization.yaml` diff check above before trusting it if significant time has passed since 2026-07-18.
