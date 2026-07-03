# Cluster Updates & Incident Log

Chronological log of fixes, incidents, and resolved issues. For ongoing operational quirks that are part of the permanent setup, see the Appendix in [README.md](README.md).

---

## 2026-07-02

### pve1 RAM confirmed bad — automated memtest (verdict for the June mon/OSD crash spree)

**Context:** ~15 daemon crashes on pve1 during June (mon.pve1 `MonitorDBStore::apply_transaction` aborts + a SIGBUS in `fn_monstore`, osd.0 AvlAllocator assert, osd.3 BlueStore spurious read errors) — all memory-corruption signatures, all confined to pve1, NVMe SMART clean. pve1 runs non-ECC DDR5 (2×32GB Crucial CT32G48C40S5), so EDAC sees nothing.

**Test (fully automated, no console access needed):** VMs drained/stopped, then (1) `memtester 50536M 1` on the bare host — OSDs/mon stayed up, cluster kept full redundancy; (2) on completion the host set `noout` and rebooted itself with `memtest=17` staged in GRUB (kernel early memtest over ~all RAM, then normal boot); (3) VMs restarted, nodes uncordoned, param removed. Logs: `pve1:/root/memtester.log`, `/root/memtest-orchestration.log`. Note: PassMark MemTest86 Free can't run unattended (config file is Pro-only) and memtest86+ never exits — the two-stage in-OS + kernel approach is the only closed-loop option.

**Verdict: FAILED.** memtester's Block Sequential test hit **2,561 failures — a contiguous ~16KB region with bit 0 stuck low** (wrote `0x1b1b…`, read `0x1a1a…`, 2,049 consecutive 8-byte offsets from buffer offset `0x504aea7e8`). Kernel early memtest found 0 bad pages (different access pattern; misses it). Hardware fault confirmed → **replace the DIMM(s)**. Until then, expect occasional pve1 daemon crashes; the failing physical region moves around VM/daemon address spaces between boots.

**Side effect worth knowing:** during memtester's initial 50GB lock/fill, pve1's sshd was starved for ~10 min (host looked down) while the kernel, OSDs, corosync and the HA watchdog all stayed healthy — check `ceph osd tree`/corosync from another node before assuming a host under memory test is dead.

**Bonus validation:** this reboot exercised the Ceph loopback cluster_network fix from earlier today — pve2 logged **zero** `heartbeat_check`/slow-ops lines during the window (vs 1,000+ blocked ops in the afternoon incident). The fix works.

### Total platform outage during pve1 reboot — Ceph OSDs bound to mesh link IPs, not loopbacks

**Symptom:** During the planned pve1 reboot, *everything* went offline (yana-stocks included) until pve1 returned — despite k8s pods being properly drained to worker-2/3 and Ceph having 2/3 hosts up. Prometheus has a total metrics gap 17:05–17:15Z; pve2's OSD logs show `heartbeat_check: no reply ... since back 17:59:40+0100` (front channel fine) and 1000+ blocked ops, "most affected pool ['rbd']".

**Root cause:** The Ceph cluster network (`cluster_network = 10.10.0.0/16`) runs over the FRR/OSPF full mesh of /30 point-to-point links. That CIDR does **not** include the OSPF loopbacks (`10.255.255.1-3`), so every OSD bound its back-channel address to a physical link IP — and by enumeration order, all six picked their **pve1-facing** link (pve2's OSDs → `10.10.10.2`, pve3's OSDs → `10.10.20.2`). When pve1 rebooted, both of those NICs lost carrier, OSPF withdrew the /30s, and pve2↔pve3 OSD replication died even though their direct link (adjacency up 9 days) was healthy the whole time. With size-3/min_size-2 pools unable to ack 2 replicas, RBD I/O froze cluster-wide → every VM (all k8s nodes) hung on disk → total outage. Asymmetric latent bug: rebooting pve3 would have been harmless; pve1 or pve2 froze storage.

**Fix:** `cluster_network = 10.255.255.0/24` in `/etc/pve/ceph.conf` (loopbacks are reachable via OSPF over any surviving link — the standard Proxmox full-mesh pattern), then restarted OSDs host-by-host under `noout` with `active+clean` gates. Verified `ceph osd metadata` shows `back_addr` on `10.255.255.x` for all six OSDs and live replication connections on loopbacks with zero on the old link IPs. Backup of the old conf: `pve1:/root/ceph.conf.bak-2026-07-02`.

**Verification for next maintenance:** a pve1/pve2 reboot should now leave `ceph pg stat` at `active+clean` and VMs responsive throughout. Front/public network (192.168.22.0/24, mons) was never affected.

### Cilium 1.17.3 → 1.18.11: HA apiserver access via k8s.apiServerURLs

**Problem:** `k8sServiceHost` was pinned to `192.168.33.21` (k8s-cp-1) — required with `kubeProxyReplacement` since the agent can't bootstrap via the in-cluster `10.96.0.1` VIP it itself implements. Consequence: any Cilium agent that (re)started while cp-1 was down crash-looped (`Start hook failed ... dial tcp 192.168.33.21:6443: connect: no route to host`) — observed on worker-3 during the 2026-07-02 pve1 reboot (3 crash-loop restarts until cp-1's apiserver returned). A single control-plane outage could take CNI management down cluster-wide with it.

**Fix:** Upgraded the chart to 1.18.11 (one-minor step, latest patch) and replaced `k8sServiceHost`/`k8sServicePort` with the 1.18 feature built for exactly this:

```yaml
k8s:
  apiServerURLs: "https://192.168.33.21:6443 https://192.168.33.22:6443 https://192.168.33.23:6443"
```

The agent load-balances/fails over across all three control planes at runtime and at bootstrap. No cert changes needed — the node IPs are already in the apiserver serving cert SANs (unlike a VIP/localhost-haproxy approach, which would have required adding SANs and regenerating certs on every control plane). 1.18 upgrade notes reviewed: no impact (no BGP/IPsec/ENI/clustermesh here; requires kernel ≥ 5.10, nodes run 6.8; no `v2alpha1` Cilium CRs in the repo).

**Residual gap (deliberate):** kubelets and kubeconfigs still point at cp-1 directly (kubeadm cluster has no `controlPlaneEndpoint`) — running workloads survive a cp-1 outage, but node heartbeats/scheduling of *new* pods on affected kubelets would stall until cp-1 returns. Fixing that properly means a VIP (kube-vip) + cert SAN regeneration + kubelet.conf updates — separate project.

### k8s-docs-pg failover deadlocked after pve1 reboot — missing apiserver-egress NetworkPolicy

**Symptom:** During a planned pve1 reboot (drain of k8s-cp-1 + k8s-worker-1), the `k8s-docs` app pods went `Init:CrashLoopBackOff` (migrate container: `EPERM` connecting to `k8s-docs-pg-rw:5432`) and the CNPG cluster sat in "Failing over" indefinitely. Chain of causes:

1. Cordoning worker-1 triggered a CNPG *switchover* (pg-1 → pg-2), but the drain deleted pg-1's pod before it could demote — the operator then waited forever ("Old primary pod not found … waiting for the operation to complete") while refusing to recreate pg-1. Cleared by patching `status.targetPrimary` back to `k8s-docs-pg-1` (`kubectl patch cluster k8s-docs-pg -n k8s-docs --subresource=status --type=merge -p '{"status":{"targetPrimary":"k8s-docs-pg-1"}}'`), which made the operator re-evaluate and start a proper *failover* to pg-2.
2. The failover then also hung: pg-2's instance manager never promoted because it couldn't reach the apiserver (`cilium monitor` showed egress `Policy denied`, remote ID `kube-apiserver`). The `k8s-docs` namespace has `default-deny-all` but was never added to `netpol-apiserver-egress.yaml` (Network Policies rule 2/3) — its `allow-egress` covers 443 (LLM APIs), but the apiserver is 6443, and even ClusterIP `10.96.0.1:443` traffic is DNAT-translated to backend `:6443` *before* policy evaluation, so the 443 rule never matches.

The gap was invisible for the cluster's first 26h because the instance manager's API watch connections predated policy enforcement and stayed alive — the reboot killed them, and every reconnect was dropped. Promotion completed within seconds of the policy landing.

**Fix:** Added `allow-kube-apiserver-egress` for `k8s-docs` to `infrastructure/network-policies/netpol-apiserver-egress.yaml`. Lesson: any namespace hosting a CNPG cluster needs apiserver egress for the *instance* pods, not just the operator namespace — and a policy gap on watch-style connections only bites when those connections are re-established (node reboot), far from when the policy was introduced.

---

## 2026-07-01

### ml.yanatech.co.uk had no public DNS record — ingest-docs CI silently failed

**Symptom:** The `ingest-docs.yml` workflow (in this repo, triggered on any `.md` change) failed with `curl` exit code 6 ("Could not resolve host") when POSTing to `https://ml.yanatech.co.uk/k8s-docs/ingest/webhook` — but the exact same URL worked fine from every other place it was tested (a homelab-connected machine, `kc1` directly, the `akan` pod). Every other `*.yanatech.co.uk` subdomain (`stocks`, `photos`, etc.) already has an explicit Cloudflare `CNAME` record → `yanatech.co.uk`, `proxied: true` — DNS here is **not wildcarded**, each public subdomain needs its own record added manually. `ml.yanatech.co.uk` simply never got one when the app was set up; every manual test up to that point happened to run from a network/host that could already resolve the internal ingress-nginx path some other way, masking the gap. GitHub Actions' hosted runner, with no such shortcut, was the first thing to actually exercise the real public path — and immediately failed.

**Fix:** Added the missing record via the Cloudflare API (same token cert-manager already uses, `/cert-manager/api-token`), identical shape to the working `stocks.yanatech.co.uk` record:
```bash
curl -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CF_TOKEN" \
  --data '{"type":"CNAME","name":"ml.yanatech.co.uk","content":"yanatech.co.uk","ttl":1,"proxied":true}'
```
Confirmed via `dig @8.8.8.8`/`dig @1.1.1.1` before and after — genuinely nothing publicly resolvable beforehand, resolving correctly (matching the other subdomains' Cloudflare proxy IPs) afterward. Re-ran the failed workflow, then did a one-off full re-ingest of all `.md` files to make sure nothing from the intervening commits (a `git diff HEAD^ HEAD` on a multi-commit push only diffs the last commit — see the shared-services entry below on this exact class of gap) was silently missed.

**Lesson for any new public-facing subdomain on `yanatech.co.uk`:** the Kubernetes-side Ingress/TLS being correctly configured says nothing about whether the DNS record actually exists — that's a separate, manual Cloudflare step, easy to forget because everything still "works" from inside the homelab network regardless.

### shared-services added — email-api + email-service

**Change:** New standalone repo `shared-services` (`github.com/akann/shared-services`, own Turborepo) deployed alongside yana-stocks/yanatech, to centralize email-sending (previously duplicated SMTP2GO logic in `auth-service` and `yanatech`'s contact form). Two NestJS apps: `email-api` (HTTP, validates + queues onto Kafka) and `email-service` (consumes the queue, sends via a swappable provider — SMTP2GO first), plus a `shared-api-docs` Redocly hub.

Cross-repo resources added here in `k8s-apps` (manifests for the apps themselves live in the `shared-services` repo's own `k8s/`, yanatech-style):
- `apps/kafka/shared-services-topics.yaml` — `KafkaTopic` CRDs `notifications-email-send` (24h retention) and `notifications-email-failed` (30d, DLQ)
- `apps/shared-services/argocd-app-shared-services.yaml` — ArgoCD Application, `repoURL` points at the `shared-services` repo, `directory.recurse: true` (its `k8s/` has nested subfolders, unlike yanatech's flat one)
- `infrastructure/network-policies/netpol-apps.yaml` — new `shared-services` namespace block: default-deny, Kong-only ingress to `email-api` (forces all callers through Kong's `key-auth` plugin rather than allowing a direct ClusterIP bypass), ingress-nginx ingress to `shared-api-docs`, kafka/SMTP2GO egress
- `infrastructure/network-policies/netpol-apiserver-egress.yaml` — apiserver egress for the new namespace (mirrors yana-stocks, needed since `email-service` uses a KEDA ScaledObject)

`email-api` is routed through Kong (`https://api-gateway.yanatech.co.uk/api/email/send`) with a `key-auth` plugin instead of an in-app auth check — same pattern as the JWT plugin already used for yana-stocks.

**Still outstanding (manual, not git-managed):** Authentik provider/application for `shared-api-docs`.

---

### shared-services deployment — first-deploy issues hit and fixed

Getting `shared-services` from "code merged" to "actually running and healthy" surfaced several gaps not visible from file review alone:

1. **Harbor unreachable from GitHub-hosted runners.** `harbor.yanatech.co.uk` doesn't resolve outside the homelab network — CI's `docker` job failed with a DNS lookup error on `ubuntu-latest`. Fix: added `infrastructure/actions-runner/argocd-app-runners-shared-services.yaml`, a dedicated per-repo ARC runner scale set (same pattern as `runners-yana-stocks`), and pointed only the `docker` job at it.
2. **No Harbor project/credential for `shared-services`.** The project didn't exist in Harbor, and (once created) the copied yana-stocks credential got a `401`/`403` — Harbor robot accounts are project-scoped, not portable. Fix: created the `shared-services` Harbor project and a dedicated robot account `robot$shared-services+ci` via the Harbor API (`POST /api/v2.0/projects`, `POST /api/v2.0/robots` with `level: project`), stored the credential in Infisical at `/shared-services/harbor/*`, and updated the GitHub repo secrets. Note: `GET/POST /api/v2.0/projects/{id}/robots` 404s on this Harbor version (v2.15.1) — use the system-wide `/api/v2.0/robots` endpoint instead, which handles both system- and project-level robots.
3. **ArgoCD couldn't clone the repo.** `shared-services` is private and had no registered credential — `ComparisonError: ... Repository not found`. Fix: added a `repository`-type Secret `repo-shared-services` in the `argocd` namespace (same shape as `repo-yanatech`/`repo-akan`: `type/url/username/password`), using a fine-grained PAT scoped to just that repo.
4. **`email-api` failing liveness/readiness probes post-deploy.** The app defaults to port 3010 (its local-dev default) when `PORT` isn't set; the k8s Service/probes target 3000. Fix: added `PORT=3000` to the Deployment env — a one-line manifest fix, no rebuild needed.

End-to-end verified after these fixes: `curl -X POST https://api-gateway.yanatech.co.uk/api/email/send` (through Kong, `key-auth` enforced) → Kafka → `email-service` → SMTP2GO, delivered successfully.

### yanatech contact form migrated to email-api

`yanatech`'s contact form (`app/api/contact/route.ts`) now POSTs to `email-api` instead of talking to SMTP2GO directly via `nodemailer`. Removed: `nodemailer`/`@types/nodemailer` deps, `SMTP_HOST/PORT/USERNAME/PASSWORD/FROM/TO` env vars, and the now-unused SMTP2GO port-2525 egress rule in `netpol-infrastructure.yaml` (yanatech's existing port-443 egress already covers the `api-gateway.yanatech.co.uk` call). Added: `EMAIL_API_URL`/`CONTACT_TO_EMAIL` (plain) and `EMAIL_API_KEY` (secret, ExternalSecret now pulls `/shared-services/email-api/EMAIL_API_KEY` instead of `/yana-stocks/auth-service/SMTP_PASSWORD`).

Follow-up fix: `email-api`'s Deployment was missing `PORT=3000` — the app falls back to its local-dev default (3010) when unset, while the Service/probes target 3000, so probes failed with connection refused post-deploy until this was added.

### akan contact form migrated to email-api

`akan`'s contact form (`app/api/contact/route.ts`) previously used Resend — but `RESEND_API_KEY` was never wired into `k8s/deployment.yaml`, so submissions were silently just `console.log`'d in production, never actually sent. Replaced with the same `email-api` pattern as yanatech. Also added the request hardening this route was missing entirely (yanatech already had it): origin check, per-IP rate limiting, `zod` validation, newline stripping. `zod` added as a new dependency. `k8s/external-secret.yaml` now also pulls `EMAIL_API_KEY`; `deployment.yaml` gets `SITE_URL`, `CONTACT_TO_EMAIL`, `EMAIL_API_URL`, `EMAIL_API_KEY`.

### auth-service (yana-stocks) migrated to email-api

`auth-service`'s `internal/email/email.go` now POSTs to `email-api` over HTTP instead of dialing SMTP2GO directly via `gomail` — `SendPasswordReset`/`SendVerification` keep identical signatures, so no callers in `internal/service/auth.go` needed to change. Removed the `gomail` dependency (`go mod tidy`) and all `SMTP_*` config; replaced with `EMAIL_API_URL` (plain) and `EMAIL_API_KEY` (secret, ExternalSecret now pulls from `/shared-services/email-api/EMAIL_API_KEY` — the old `SMTP_*` keys under `/yana-stocks/auth-service/` are left in place, unreferenced). Removed the now-unused SMTP2GO port-2525 egress rule from `netpol-apps.yaml`'s yana-stocks section — auth-service was its only consumer (`email-service`'s own rule for its direct SMTP2GO connection, in the shared-services section, is untouched).

All three original SMTP2GO callers (`auth-service`, `yanatech`, `akan`) are now migrated — nothing calls SMTP2GO directly except `email-service` itself.

**ArgoCD gotcha hit during this rollout:** after pushing, `yana-stocks`' ArgoCD Application stayed `Synced` at the *old* revision for several minutes despite `argocd.argoproj.io/refresh: hard` — the repo-server's local git clone was stale (evidenced by suspiciously fast `git_ms` timings in the controller logs, consistent with a cache hit rather than a real fetch). Fix: `kubectl rollout restart deployment argocd-repo-server -n argocd`, then refresh again. Also: re-patching the `refresh` annotation to the *same* value (`hard` → `hard`) is a no-op — Kubernetes only fires a change event if the value actually differs, so alternate between e.g. `hard`/`hard-2` or remove-then-reapply. Hit this same staleness two more times later the same day when pushing further `shared-services` and `yana-stocks` fixes — same fix each time (`kubectl rollout restart deployment argocd-repo-server -n argocd`).

### email-service: dropped the retry loop

Removed the 3-attempt retry-then-DLQ logic in `email-consumer.service.ts`, down to a single attempt straight to the DLQ on failure. Retry only ever covered the `email-service`↔SMTP2GO hop (SMTP2GO's own best-effort delivery already owns the SMTP2GO↔recipient hop, which this app has no visibility into anyway); it also couldn't distinguish a permanent failure (bad address, auth) from a transient one, and risked a duplicate send if a prior attempt actually succeeded but timed out waiting for the ack. Given the traffic volume, correctly classifying SMTP error codes to retry selectively wasn't worth the added fragility. The DLQ (`notifications.email.failed`) is unaffected and still does the real work.

### shared-services: ArgoCD self-heal was fighting KEDA's scale-to-zero

`email-service` scales 0→3 via a KEDA `ScaledObject`, but its Deployment manifest also declares a static `replicas: 1`. Every ArgoCD sync reset `replicas` back to 1 (self-heal working as designed), which KEDA then scaled back down moments later — visible as a new pod being created and torn down right after every routine sync. Fix: added an `ignoreDifferences` entry for `/spec/replicas` on `email-service` to `argocd-app-shared-services.yaml` — yana-stocks' Application already has this for all six of its KEDA-scaled Deployments; it was just missed when scaffolding this one.

### OpenAPI specs were missing an explicit `servers` entry

`email-api` and all four yana-stocks NestJS services (`profile-service`, `portfolio-service`, `portfolio-api`, `price-processor`) generate their OpenAPI specs with `DocumentBuilder` but never called `.addServer(...)`. With `servers: []`, Redoc/Swagger UI default the "try it" base URL to the hosted docs page's own origin (`shared-api-docs.yanatech.co.uk` / `api-docs.yanatech.co.uk`) instead of the real API host. Fixed by adding `.addServer('https://api-gateway.yanatech.co.uk', ...)` to both `main.ts` (live Swagger UI) and `generate-openapi.ts` (static hosted docs) for each service, plus a second `http://localhost:<dev-port>` entry so the hosted docs can also target a local dev instance. `auth-service` (Go/swaggo) got the equivalent `@host`/`@schemes` annotations — Swagger 2.0 only supports one host, so no localhost alternative there.

### CI gotcha: a cancelled run can silently drop a change from ever being built

Pushed a fix to `auth-service` (the `@host` annotation above), then pushed a second unrelated fix before the first CI run finished — `concurrency.cancel-in-progress` correctly killed the first run. The second run's `changes` job (dorny/paths-filter) only diffs against the commit immediately before *that* push, so a file only changed in the *cancelled* run's commit doesn't register as changed the second time either — `auth-service` silently never got rebuilt. Caught by checking which `docker/*` jobs actually ran in the successful workflow. Recovery: `gh workflow run ci.yml -f build_all=true` (the workflow already has a `workflow_dispatch` input for this) forces every service to rebuild regardless of detected changes.

---

## 2026-06-30

### kured permanently stuck on k8s-worker-2 — drainTimeout + forceReboot fix

**Symptom:** `k8s-worker-2` was cordoned by kured (`node.kubernetes.io/unschedulable: kured`) but never rebooted. kured was stuck in an infinite drain-eviction loop, retrying every 60s.

**Root cause:** All CNPG clusters had `instances: 1`. A single-instance CNPG cluster creates two PDBs:
- `<name>` — allows 0 disruptions on the replica set (empty, no replicas)
- `<name>-primary` — `minAvailable: 1` on the primary, meaning `ALLOWED DISRUPTIONS: 0`

kured's drain cannot evict the primary pod; the node never drains, so reboot never happens, so the node stays cordoned.

**Fix — two parts:**
1. Scale all CNPG clusters to ≥ 2 instances so the primary can failover during drain:
   - `auth-service-pg`: 1 → 2 instances (`apps/yana-stocks/auth-service/cnpg-cluster.yaml`)
   - `immich-postgres`: 1 → 2 instances (`apps/immich/postgres-cluster.yaml`)
   - `pg-main`: 3 → 4 instances (`infrastructure/cnpg-clusters/pg-main.yaml`)
2. Add drain timeout + force-reboot to kured so primary nodes get rebooted even if drain times out (CNPG recovers via WAL replay):
   - `infrastructure/kured/argocd-app-kured.yaml`:
     ```yaml
     drainTimeout: 5m
     forceReboot: true
     ```

---

### CNPG backups — auth-service-pg had no backup coverage

**Problem:** `auth-service-pg` had no barman configuration and no ScheduledBackup. Data loss risk: entire DB.

**Fix:**
- Added barman backup block to `apps/yana-stocks/auth-service/cnpg-cluster.yaml`:
  - WAL streaming + daily base backup → MinIO `s3://cnpg-backups/auth-service-pg/`
  - 7-day retention, gzip compression
- New `apps/yana-stocks/auth-service/external-secret-minio.yaml` — provisions `cnpg-minio-credentials` from Infisical keys `/cnpg-clusters/MINIO_ACCESS_KEY_ID` and `/cnpg-clusters/MINIO_SECRET_KEY`
- New `apps/yana-stocks/auth-service/scheduled-backup.yaml` — daily ScheduledBackup at 01:00

---

### Velero — PVC data not being backed up

**Problem:** Velero had `snapshotsEnabled: false` and no `node-agent` DaemonSet. Only Kubernetes API objects (Deployments, Services, CRDs, etc.) were backed up — no PVC contents.

**Fix:** Updated `infrastructure/velero/argocd-app-velero.yaml`:
- `deployNodeAgent: true` — enables Kopia fs-backup DaemonSet on all nodes
- `defaultVolumesToFsBackup: true` in the daily schedule template — all PVCs included by default

---

### harbor-database — no backup coverage

**Problem:** `harbor-database` is a plain StatefulSet (`goharbor/harbor-db`), not managed by CNPG. No backup existed.

**Fix:**
- New `infrastructure/harbor/db-backup-cronjob.yaml` — CronJob `harbor-db-backup` runs daily at 04:00:
  - initContainer: `postgres:16-alpine` pg_dumps the `registry` DB → `/backup/harbor-$(date +%A).sql.gz` (rolling 7-day filenames)
  - main container: `amazon/aws-cli` uploads to MinIO `s3://cnpg-backups/harbor-db/`
- New `infrastructure/harbor/external-secret-minio.yaml` — provisions `minio-backup-credentials` in `harbor` namespace
- New `infrastructure/harbor/argocd-app-harbor-backup.yaml` — new ArgoCD Application `harbor-backup` (wave 9) pointing to `infrastructure/harbor/`
- Added `infrastructure/harbor/argocd-app-harbor-backup.yaml` to root `kustomization.yaml`

---

### Loki chunks-cache excessive memory usage

**Problem:** Default `chunksCache.allocatedMemory: 8192` (8Gi) caused Loki to reserve 8Gi of RAM on k8s-worker-1, contributing to high memory pressure.

**Fix:** Set `chunksCache.allocatedMemory: 2048` (2Gi) in `infrastructure/loki/argocd-app-loki.yaml`. Saved ~6Gi working memory on worker-1.

---

### KEDA gRPC timeout — metrics-apiserver blocked by NetworkPolicy

**Problem:** KEDA `metrics-apiserver` could not reach the KEDA operator gRPC endpoint (port 9666) within the `keda` namespace. The `default-deny-all` NetworkPolicy blocked intra-namespace traffic not explicitly whitelisted.

**Fix:** Added intra-namespace ingress rule for port 9666 to the `allow-keda` policy in `infrastructure/network-policies/netpol-infrastructure.yaml`:
```yaml
- from:
    - podSelector: {}   # metrics-apiserver → operator gRPC
  ports:
    - port: 9666
```

---

### Empty MinIO buckets deleted

Deleted stale empty buckets `yana-stocks-datasets` and `yana-stocks-exports` from MinIO (`minio-console.yanatech.co.uk`). These were never populated; no data lost.

---

### yana-stocks OutOfSync — KEDA replica drift on portfolio-api, portfolio-service, profile-service

**Symptom:** `yana-stocks` app showing OutOfSync for three deployments — live `replicas: 2`, git `replicas: 1`.

**Root cause:** KEDA ScaledObjects scale these deployments at runtime. ArgoCD sees the live replica count diverge from the manifest's static value and flags it as OutOfSync. Same cosmetic issue as `price-ingestor`, `price-processor`, `sentiment-analyzer` (already fixed).

**Fix:** Added `/spec/replicas` to `ignoreDifferences` for all three in `apps/yana-stocks/argocd-app-yana-stocks.yaml`.

---

### akan personal site deployment + nkweini.org wildcard TLS

**Change:** Added ArgoCD Application `akan-deployment` (wave 9) pointing at `github.com/akann/akan` path `k8s/` — deploys the personal site to `akan.nkweini.org` in its own `akan` namespace.

Added cert-manager resources for `*.nkweini.org`:
- `infrastructure/cert-manager/certificate-nkweini.yaml` — Certificate for `nkweini.org` + `*.nkweini.org`, secret `wildcard-nkweini-tls` in `ingress-nginx` ns, Reflector auto-propagated to all namespaces
- `infrastructure/cert-manager/external-secret-nkweini.yaml` — pulls Cloudflare API token scoped to nkweini.org from Infisical `/cert-manager/api-token-nkweini`
- `infrastructure/cert-manager/clusterissuer.yaml` — updated to add a second DNS-01 solver for `nkweini.org` zone using the `cloudflare-api-token-nkweini` secret

---

### Reflector annotation keys corrected in wildcard-nkweini certificate

**Problem:** Initial commit used incorrect Reflector annotation keys (`reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces` instead of `reflection-auto-namespaces`), so Reflector wasn't propagating the `wildcard-nkweini-tls` secret.

**Fix:** Updated `infrastructure/cert-manager/certificate-nkweini.yaml` to use:
```yaml
reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: ".*"
```

---

### Kong ValidatingWebhookConfiguration — timeoutSeconds reduced to 5

**Problem:** `kong-controller-kong-validations` ValidatingWebhookConfiguration had `timeoutSeconds: 10` on all three webhook entries. In Cilium native routing mode, each kube-apiserver→webhook call takes ~10s. Two sequential calls (webhooks 0 and 1 both intercept all Secrets cluster-wide) consumed 20s total, exceeding cert-manager's context deadline and blocking TLS secret SSA PATCHes.

All three webhooks affected:
- index 0 — `secrets.credentials.validation.*` (all secrets cluster-wide)
- index 1 — `secrets.plugins.validation.*` (all secrets cluster-wide)
- index 2 — `services.validation.*` (all Service CREATE/UPDATE — was also breaking Strimzi)

**Fix:** Patched `timeoutSeconds: 5` on all three webhook entries. Added indices 0, 1, 2 to `ignoreDifferences` in `infrastructure/kong/argocd-app-kong.yaml` so ArgoCD doesn't revert the live patch.

---

### ml added — k8s-docs RAG chatbot

**Change:** New standalone repo `ml` (`github.com/akann/ml`, own Turborepo, meant to grow into more ML apps over time) deployed as this workspace's first RAG chatbot: answers questions about `k8s-apps`' docs, indexed via pgvector, served at `akan.nkweini.org/k8s-docs`. First app, `k8s-docs` (NestJS), in namespace `k8s-docs`.

Cross-repo resources added here in `k8s-apps` (app manifests live in the `ml` repo's own `k8s/`, shared-services-style):
- `apps/ml/argocd-app-ml.yaml` — ArgoCD Application, `directory.recurse: true`, includes `ignoreDifferences` for both `ExternalSecret` (ESO-injected defaults) and CNPG `Cluster` (admission-webhook-injected defaults) — copied verbatim from `apps/immich/argocd-app-immich.yaml` since it's the same two CRDs
- `infrastructure/actions-runner/argocd-app-runners-ml.yaml` — dedicated per-repo ARC runner, same pattern as `runners-shared-services`
- `infrastructure/cilium/ciliumnetpol-akan-k8s-docs.yaml` — lets `akan`'s server reach `k8s-docs`'s Service internally (see the network policy regression entry below)
- `infrastructure/network-policies/netpol-apps.yaml` — new `k8s-docs` namespace block: default-deny, ingress-nginx-only for `/ingest`+`/health` (not `/query` — see below), `akan`-namespace-only ingress on port 3000 for `/query`, CNPG operator ingress
- `infrastructure/network-policies/netpol-cnpg.yaml` — added `k8s-docs` to `cnpg-system`'s operator egress allowlist (same list `immich`/`yana-stocks` are already in)

**Design decisions worth remembering:**
- **`/query` is not on the public Ingress.** Only `/ingest/webhook` and `/health` are. The chat page's server (`akan`) reaches `/query` over internal Service DNS, restricted by the CiliumNetworkPolicy above — an API key is checked in-app too, but the network policy is the actual control keeping it unreachable from the internet.
- **Content scope is deliberately just `k8s-apps`**, not the other private repos in this workspace, because the chat page is public with no page-level auth — indexing a private repo would let anyone read it via the chatbot as a side channel. Don't add another repo to the ingestion workflow without gating the page behind Authentik first.

**Still outstanding (manual, not git-managed):** none currently — Harbor project/robot, ArgoCD repo credential, and all Infisical secrets for this app were provisioned directly against the live cluster during setup.

### k8s-docs first-deploy issues hit and fixed

Same story as shared-services' first deploy: three real bugs, none caught by code review, all caught by actually running the thing.

1. **CNPG's `bootstrap.initdb.secret` doesn't auto-generate the secret it names.** Assumed it would, like most operators' reference-or-create pattern. It doesn't — the bootstrap job hung for 9 minutes on `secret not found`. Fix: a dedicated `ExternalSecret` (`k8s-docs-db-credentials`, type `kubernetes.io/basic-auth`) has to pre-create it, same pattern as `apps/immich/external-secret.yaml`'s `immich-db-credentials` — which I'd copied the `Cluster` manifest from but missed the second file it depends on.
2. **A correctly-declared dependency was unreachable at runtime.** `express` (a real dependency of `@nestjs/platform-express`, correctly resolved in the lockfile) wasn't linked into that package's own `node_modules` after a `pnpm install --frozen-lockfile --prod` in the Docker production stage — the app crashed on boot with `Cannot find module 'express'`. Type-check, lint, and `nest build` all passed; none of them load the compiled code, so none caught it. Reproduced outside Docker too (plain local install, same failure) — not Docker- or `--prod`-specific. Fixed with `shamefully-hoist=true` in `.npmrc`. Only found by actually running the built image.
3. **A new NetworkPolicy broke a feature it had nothing to do with.** `ciliumnetpol-akan-k8s-docs.yaml` was the *only* policy ever selecting `app: akan` pods. The moment it applied, Cilium switched those pods to default-deny egress except the one explicit rule — silently breaking DNS and the contact form's call to `api-gateway.yanatech.co.uk`, not just adding the intended k8s-docs access. Fixed with a `toEntities: [all]` rule alongside the specific one, restoring `akan`'s original fully-open posture. See Network Policies rule 7 in CLAUDE.md — this is now a documented gotcha, not just a one-off fix.

Also caught after the fact: the `ingest-docs.yml` workflow's `paths:` trigger only matched `CLAUDE.md`, `docs/**/*.md`, and root `README.md` — missing 12 real files (9 per-app/infra `README.md`s, `proxmox-cluster-setup.md`, `pve-node-operations.md`, `README_AWS.md`, `UPDATES.md`). Widened to `**/*.md` and backfilled all previously-missed files via a one-off call to the ingest webhook.

---

## 2026-06-29

### KEDA Kafka ScaledObjects added to remaining yana-stocks consumers

**Change:** Added `keda-scaledobject.yaml` to `price-processor`, `profile-service`, `portfolio-service`, and `portfolio-api`. All use lag threshold 100 on their respective topics, matching the existing `sentiment-analyzer` pattern.

| Service | min | max | Topic(s) |
|---|---|---|---|
| price-processor | 0 | 3 | `stocks.prices.raw` |
| profile-service | 1 | 3 | `users.registered` |
| portfolio-service | 1 | 3 | `stocks.prices.processed`, `users.registered` |
| portfolio-api | 1 | 3 | `stocks.prices.processed`, `stocks.signals.sentiment`, `stocks.signals.prediction` |

`price-processor` scales to 0 (pure pipeline, no user-facing cold start). `profile-service` keeps min 1 because profile creation must be near-immediate post-registration. `portfolio-service` and `portfolio-api` keep min 1 because they serve HTTP traffic.

---

## 2026-06-24

### Kong `RepeatedResourceWarning` — 12 duplicate CRDs (resolved)

**Symptom:** ArgoCD reported `RepeatedResourceWarning` for 12 Kong CRDs — each one "appeared 2 times among application resources".

**Root cause:** The `ingress` chart v0.24.0 embeds the `kong` sub-chart **twice** via Helm dependency aliases (`controller` and `gateway`). Each alias has its own `crds/` directory, which ArgoCD includes via `--include-crds`. Additionally, ArgoCD renders against the live cluster, so the sub-chart template's `lookup()` detects existing CRDs and also renders them from `templates/custom-resource-definitions.yaml` — producing two copies per CRD.

**Fix:** Set `ingressController.installCRDs: false` on both aliases in `infrastructure/kong/argocd-app-kong.yaml`. This forces the template to take the explicit-value path and skip CRD rendering, leaving `crds/` as the sole managed source.

```yaml
# infrastructure/kong/argocd-app-kong.yaml
gateway:
  ingressController:
    installCRDs: false
controller:
  ingressController:
    installCRDs: false
```

---

### Kured drain blocked by CNPG PDB (k8s-worker-1 reboot)

**Symptom:** kured cordoned `k8s-worker-1` after a kernel update but was stuck in an eviction loop for 6+ hours. Two CNPG primary pods were on the node: `pg-main-4` (`cnpg-clusters`) and `immich-postgres-1` (`immich`). Both had `disruptionsAllowed: 0` on their PDBs.

**Root cause:** `kubectl drain` uses the eviction API, which **respects PodDisruptionBudgets**. CNPG sets `minAvailable: 1` on primary pods, so `disruptionsAllowed` is always 0 while only one primary exists.

**Fix:** Delete the primary pods directly — `kubectl delete pod` bypasses PDB (delete API vs eviction API). CNPG immediately promotes the most-up-to-date standby on another node.

```bash
# Identify CNPG pods on the cordoned node
kubectl get pods -A -o wide --field-selector spec.nodeName=<node>

# Direct delete bypasses PDB — CNPG auto-promotes standby
kubectl delete pod <pg-main-N> -n cnpg-clusters
kubectl delete pod <immich-postgres-N> -n immich

# kured proceeds with drain and reboot automatically
# After reboot, deleted pods are recreated as standby replicas
```

---

### CNPG standby stuck in WAL replay — timeline mismatch (pg-main-2)

**Symptom:** `pg-main-2` was 0/1 Running for 8+ hours with 8+ restarts. Logs showed a loop:
```
"waiting for WAL to become available at 13/9E11F740"
"Refusing to restore future timeline history file" fileTimeline:15 clusterTimeline:14
```

**Root cause:** The pod's PVC held stale data from a timeline the cluster had already advanced past (multiple primary failovers during the kured incident bumped the timeline to 15; the PVC was stuck on 14). Deleting just the pod did **not** fix this — CNPG reattached the same PVC and the instance resumed from the same stuck position.

**Fix:** Delete both the pod and its PVC. CNPG provisions a new PVC, creates a join pod that runs `pg_basebackup` from the primary (~30–60 s), then starts the new standby on the correct timeline.

```bash
kubectl delete pod pg-main-2 -n cnpg-clusters --wait=true
kubectl delete pvc pg-main-2 -n cnpg-clusters

# CNPG creates pg-main-5-join-xxxxx → pg-main-5 (1/1 Running)
# Cluster returns to: Cluster in healthy state 3/3
```

**Note:** CNPG increments instance numbers monotonically and never reuses them. After this incident the pg-main instances are `pg-main-1` (primary, kw2), `pg-main-4` (standby, kw2), `pg-main-5` (standby, kw1).

---

### kube-scheduler and kube-controller-manager on cp-2/cp-3 pointing to wrong API server (resolved)

**Symptom:** `kube-scheduler-k8s-cp-2` and `kube-scheduler-k8s-cp-3` were `0/1 Running` (37 and 0 restarts over 12h respectively). `kube-controller-manager-k8s-cp-2/3` were `1/1 Running` but completely non-functional. All four components logged the same error:

```
dial tcp 192.168.22.22:6443: i/o timeout    # cp-2
dial tcp 192.168.22.23:6443: i/o timeout    # cp-3
```

**Root cause:** `/etc/kubernetes/scheduler.conf` and `/etc/kubernetes/controller-manager.conf` on both cp-2 and cp-3 had `server: https://192.168.22.2x:6443` — the Proxmox management network IPs (vmbr0, VLAN 22), not the Kubernetes network IPs (vmbr1, VLAN 33). The cluster's Kubernetes workloads live entirely on `192.168.33.x`; the management IPs are unreachable from within the cluster. The misconfiguration was present since the control plane nodes joined (likely kubeadm picked up the primary NIC which was the management interface). `kubelet.conf` and `admin.conf` on the same nodes correctly pointed to `192.168.33.21:6443` and were unaffected.

The cluster appeared healthy because cp-1's scheduler and controller-manager (both correctly configured) won leader election and handled all scheduling/control work. The other two replicas were silently dead, leaving the cluster with no HA on scheduler or controller-manager.

**Fix:**

```bash
# On k8s-cp-2
sudo sed -i 's|server: https://192.168.22.22:6443|server: https://192.168.33.21:6443|g' \
  /etc/kubernetes/scheduler.conf /etc/kubernetes/controller-manager.conf

# On k8s-cp-3
sudo sed -i 's|server: https://192.168.22.23:6443|server: https://192.168.33.21:6443|g' \
  /etc/kubernetes/scheduler.conf /etc/kubernetes/controller-manager.conf

# Restart static pods by briefly moving manifests out then back (kubectl delete pod is a no-op for
# static pods — kubelet recreates the mirror pod without restarting the container)
sudo mv /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/ && sleep 5 && \
  sudo mv /tmp/kube-scheduler.yaml /etc/kubernetes/manifests/
sudo mv /etc/kubernetes/manifests/kube-controller-manager.yaml /tmp/ && sleep 5 && \
  sudo mv /tmp/kube-controller-manager.yaml /etc/kubernetes/manifests/
```

Result: all 6 control plane components `1/1 Running`, clean leader election logs, full HA restored.

---

### alertmanager-gotify-bridge 401 Unauthorized (resolved)

**Symptom:** `alertmanager-gotify-bridge` was `1/1 Running` but flooding logs with:
```
Non-200 response from gotify at http://gotify.gotify.svc.cluster.local/message. Code: 401, Status: 401 Unauthorized
```

**Root cause:** The token stored in Infisical at `/gotify/ALERTMANAGER_TOKEN` (`AvMQK99JPxH2tYh`) did not match any active application token in Gotify. The Gotify "Alert Manager" app (id:3) had been recreated/regenerated at some point with a new token (`A7bvx9Aev_TS8GJ`), but Infisical was never updated. ESO was faithfully syncing the stale token into `gotify-secret`. This was masked for 18+ days by a concurrent NetworkPolicy bug (i/o timeout) that was fixed first.

**Token discovery:**
```bash
ADMIN_PASS=$(kubectl get secret gotify-secret -n gotify -o jsonpath='{.data.admin-password}' | base64 -d)
curl -s -u "admin:$ADMIN_PASS" https://gotify.yanatech.co.uk/application
# Returns all apps with their valid tokens
```

**Fix:**
1. Patched `gotify-secret` directly with the correct token
2. Restarted the bridge deployment
3. **Updated Infisical `/gotify/ALERTMANAGER_TOKEN`** with `A7bvx9Aev_TS8GJ` (required — ESO refreshes every 1h and would overwrite the patch otherwise)

```bash
kubectl patch secret gotify-secret -n gotify --type='json' \
  -p='[{"op":"replace","path":"/data/alertmanager-token","value":"<base64-of-token>"}]'
kubectl rollout restart deployment alertmanager-gotify-bridge -n gotify
```

Result: bridge starts cleanly, no 401 errors, no i/o timeouts.

---

## 2026-06-28/29

### Harbor Degraded — RWO PVC rolling update deadlock (resolved)

**Symptom:** Harbor showed `Degraded` in ArgoCD for 94+ minutes. `harbor-jobservice` and `harbor-registry` had new RS pods stuck in `ContainerCreating` with no events (events expire after ~1h). kubelet on k8s-worker-2 logged:
```
unmounted volumes=[job-logs], unattached volumes=[job-logs], failed to process volumes=[]: context deadline exceeded
```

**Root cause:** Two compounding issues:
1. `targetRevision: "*"` in `argocd-app-harbor.yaml` caused an uncontrolled chart upgrade when a new Harbor chart version was published.
2. The upgrade triggered a rolling update. The new pods were scheduled on `k8s-worker-2`; the old pods (with RWO Ceph RBD PVCs) were on `k8s-worker-1`. Kubernetes deadlock: new pods can't mount the volume (held by old pods on another node), old pods won't terminate (rolling update waits for new pods to be Ready first).

**Why kubectl rollout undo failed:** ArgoCD's `selfHeal: true` immediately re-applied the git state, overwriting the rollback within seconds.

**Fix:**
1. Patched `harbor-jobservice` and `harbor-registry` Deployments directly to `Recreate` strategy, breaking the deadlock:
```bash
kubectl patch deployment harbor-jobservice -n harbor \
  -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'
kubectl patch deployment harbor-registry -n harbor \
  -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'
```
All pods Running within 1 minute.

2. Updated git:
   - `targetRevision: "*"` → `targetRevision: "1.19.1"` (pin chart version)
   - Added top-level `updateStrategy: {type: Recreate}` to Helm values (Harbor chart uses `.Values.updateStrategy.type`, not per-component keys)

**Key lesson:** Harbor's jobservice and registry use RWO PVCs. `updateStrategy: Recreate` must be set at the **top level** of Harbor Helm values — not under `jobservice:` or `registry:` (those keys are silently ignored by the chart template).

```yaml
# argocd-app-harbor.yaml (correct location)
helm:
  valuesObject:
    updateStrategy:
      type: Recreate
```

---

### Gotify Authentik forward auth — attempted, reverted

**Context:** Added Authentik forward auth to Gotify to avoid exposing it with only its own login. Configured an Authentik provider, application, and outpost via the Authentik UI, then added auth annotations and an outpost ingress to `gotify.yaml`.

**Problem:** Authentik forward auth and application-level auth are orthogonal concerns. Authentik acts as an access gate (decides who can reach the URL). Once through, Gotify still presents its own login screen. Gotify is a React SPA using `localStorage` tokens — nginx/Authentik cannot inject credentials or bypass the app's internal auth flow. The result was two sequential login screens, which is worse UX than no Authentik at all.

**Revert:** Removed auth annotations and outpost ingress from `gotify.yaml`, removed `ak-outpost-svc.yaml` (ExternalName service). The `/message` and `/stream` bypass ingress (`gotify-api`) was retained for the alertmanager bridge.

**Conclusion:** Forward auth is only appropriate for apps that either (a) have no auth of their own, or (b) support header-based SSO injection. Gotify's SPA architecture makes it incompatible with forward auth as an SSO replacement.

---

### Alertmanager email notifications removed

**Change:** Removed all email routing from Alertmanager. Previously `critical-alerts` receiver sent to both Gotify and SMTP2GO; now all alerts route to Gotify only.

Removed from `argocd-app-monitoring.yaml`:
- `global.smtp_*` settings
- `email_configs` from `critical-alerts` receiver
- `grafana-smtp-secret` volume + volume mount from `alertmanagerSpec`

The `external-secret-smtp.yaml` and `grafana-smtp-secret` secret still exist but are no longer referenced by Alertmanager. The `grafana-smtp-secret` ESO resource can be deleted if Grafana SMTP is also not needed.

---

### ArgoCD app health alerts → Gotify via Prometheus

**Problem:** No visibility into ArgoCD app health changes (Degraded, Missing, OutOfSync) — discovered Harbor was Degraded only by chance.

**Fix:**

1. **ArgoCD controller metrics** — enabled via `infrastructure/argocd/values.yaml`:
```yaml
controller:
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
      additionalLabels:
        release: kube-prometheus-stack
```
This creates a `Service` on port 8082 and a `ServiceMonitor` so Prometheus scrapes `argocd_app_info` from the ArgoCD application controller.

2. **PrometheusRule** — `infrastructure/monitoring/rules/prometheusrule-argocd.yaml`:
   - `ArgoCDAppDegraded` (critical, 5m) — fires when `health_status="Degraded"`
   - `ArgoCDAppMissing` (critical, 5m) — fires when `health_status="Missing"`
   - `ArgoCDAppOutOfSync` (warning, 15m) — fires when `sync_status="OutOfSync"`

3. **Alertmanager routing** — critical alerts → Gotify (already configured). The PrometheusRule labels `severity: critical` for Degraded/Missing, so they route to the `critical-alerts` receiver → Gotify bridge.

---

### Real visitor IPs in ingress-nginx access logs (2026-07-03)

**Problem:** Access logs showed node IPs (e.g. `192.168.33.31`) for every external request — useless for seeing who visits `akan.nkweini.org` or any other public host. Two layers hid the client: `externalTrafficPolicy: Cluster` SNATs the connection to a node IP, and the sites are behind Cloudflare's proxy anyway, so the L3 source is a Cloudflare edge, with the real visitor only in the `CF-Connecting-IP` header.

**Fix** (`infrastructure/ingress-nginx/argocd-app-ingress-nginx.yaml`):

1. `controller.service.externalTrafficPolicy: Local` — preserves the L3 source (the Cloudflare edge IP). MetalLB L2 only announces the VIP from nodes with a ready controller pod, so 2 replicas keep failover.
2. `use-forwarded-headers: "true"` + `forwarded-for-header: CF-Connecting-IP` + `proxy-real-ip-cidr: <Cloudflare IPv4 ranges>` — nginx swaps `$remote_addr` to the visitor IP from the Cloudflare header, but only when the connection actually comes from a Cloudflare range (spoof-safe).

**Notes:**
- Step 2 depends on step 1 — with `Cluster`, the SNAT'd node IP never matches the Cloudflare CIDR list and the header is ignored.
- LAN visitors resolve the hosts to the VIP directly (split-horizon) and log their real LAN IP with no header involved.
- Cloudflare ranges change rarely; source is https://www.cloudflare.com/ips-v4 — refresh the `proxy-real-ip-cidr` list if logs ever start showing 172.64.x/104.x sources again.
- nginx does not reverse-resolve DNS names in access logs; look up interesting IPs after the fact (`dig -x <ip>`) or in Grafana/Loki.
