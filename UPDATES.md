# Cluster Updates & Incident Log

Chronological log of fixes, incidents, and resolved issues. For ongoing operational quirks that are part of the permanent setup, see the Appendix in [README.md](README.md).

---

## 2026-08-18

### Transient B2 read failure took out 5 kopia maintenance jobs — NOT a repeat of the 17th

At 21:40–21:42 UTC, five Velero kopia maintenance jobs failed in sequence (pgadmin,
vaultwarden, mongodb, nextcloud, uptime-kuma), each with
`error loading index blob ... unexpected EOF`. The alert named only vaultwarden and
advised removing the failed job. Given the 2026-08-17 silent-data-loss incident had the
same surface symptom — and there the same advice was actively wrong — this was
investigated before touching anything.

**How to tell the two apart: check WHICH blob failed.** vaultwarden failed on
`xn0_e1b7fa3d…`, uptime-kuma on a completely different `xn0_d527d77c…`, in different
repos inside the same two-minute window. Object corruption does not distribute like
that; a degraded read path does. On the 17th the failures were *deterministic* — the
same objects failing 3/3 retries, even on a 1 KB ranged GET.

Confirmed transient, not corruption:

- Both implicated blobs now full-read clean 3/3 at exact size (565/565 and 3907/3907).
- All 8 critical small blobs in `kopia/vaultwarden` (`xn`/`xe`/`xw`/`kopia.*`/`udmrepo`)
  full-read clean.
- Every one of the five repos maintained **successfully** on the next run at ~22:50.
- No CNPG WAL-archiving failures against the same B2 provider in that window.
- BSL `Available`; `velero-weekly-backup-20260817114110` is `Completed`, 0 errors,
  0 warnings, 9026/9026 items, 23/23 PodVolumeBackups.

The five failed Job objects were deleted after this diagnosis, which cleared the alert.

**Two traps worth remembering.** `kubectl get backup -n velero` returns *nothing* — the
short name resolves to CNPG's `backups.postgresql.cnpg.io`, not Velero's. It reads
exactly like "no backups exist". Always use `kubectl get backups.velero.io`. Separately,
`VeleroBackupPartialFailure` is currently firing and is expected to keep firing until
about 2026-08-24: it counts `increase(velero_backup_partial_failure_total[8d])`, and the
single event in that window is the 2026-08-16 weekly run — the one that preceded the
data-loss discovery and was already remediated. It will self-clear as the event ages out.

### Two pg-main replicas silently diverged for 9 days; unbounded slot WAL retention filled a volume

A `PersistentVolume` fill-prediction alert fired for `pg-main-1` in `cnpg-clusters` (14.64% free, ~4 days to full). The disk was the symptom; the cause was that **two of the four `pg-main` replicas had not replicated in 9 days while everything reported healthy.**

**Root cause.** Repeated failovers walked the cluster from timeline 54 to 58. At the 54→55 fork (LSN `45/940000A0`), `pg-main-2` and `pg-main-4` had already replayed to `45/95000000` — roughly 16 MB *past* the fork point — so they held WAL records that were never part of the surviving history. Postgres correctly refused to let them follow the new timeline:

```
FATAL: could not start WAL streaming: ERROR: requested starting point 45/95000000
on timeline 54 is not in this server's history
DETAIL: This server's history forked from timeline 54 at 45/940000A0.
```

Both sat in that retry loop from 2026-08-09, each with an empty `pg_stat_wal_receiver`, replay frozen at a 9d 7h lag. Their replication slots stayed defined but inactive, and with `max_slot_wal_keep_size = -1` (the default, unlimited) they pinned WAL indefinitely: 26 GB on the primary `pg-main-5` via `_cnpg_pg_main_2`, and 42 GB on `pg-main-1` via the HA-synced copy of `_cnpg_pg_main_4`. `pg-main-1` reached 43 GB of `pg_wal` (1,645 segments) against a 269 MB database.

**Nothing detected any of this.** `kubectl get cluster` reported `Cluster in healthy state` and listed all four instances under `status.instancesStatus.healthy`; all four pods were `1/1 Running`. A storage alert stood in for a replication alert, 4 days before the volume would have run out.

**Fix.** Re-bootstrapped both diverged instances the standard CNPG way — delete the instance PVC, then the pod, and let the operator re-clone from the primary. `pg-main-4` was re-created as `pg-main-3` (the operator picks the lowest free serial, which is also why the set had been 1,2,4,5). Each clone took ~30 seconds at this database size. The primary was never restarted and no failover occurred, so there was no application-facing interruption.

Once the slots went active again the retained WAL was released at the next restartpoint: `pg-main-1` 43 GB/88% → 945 MB/2%, primary 26 GB → 867 MB. All three replicas now stream with sub-second lag and all three slots report 0 bytes retained.

**Data note.** The two destroyed volumes held the only remaining copy of the ~16 MB of timeline-54 WAL orphaned at the 9-day-old promotion. Those transactions were already lost to the cluster then — ordinary asynchronous-replication failover behaviour — and were unreachable across four subsequent timeline changes, but the re-bootstrap did discard the last physical copy.

### Migrated all 7 CNPG clusters from in-tree Barman Cloud to the Barman Cloud Plugin

Surfaced by a deprecation warning during the pg-main work above: CNPG's in-tree
`spec.backup.barmanObjectStore` is deprecated since 1.26 and **removed in 1.31.0**.
All seven clusters backed up through it, so this gated the next operator upgrade.

Installed `plugin-barman-cloud` chart 0.7.1 (plugin v0.14.0) as its own ArgoCD
Application at sync-wave 8 — before `cnpg-clusters` (9) and the app namespaces,
since a Cluster referencing a plugin that is not yet running cannot archive WAL.
Pinned rather than `"*"`, unlike the operator, because it sits in the backup path.

Migrated: `pg-main`, `immich-postgres`, `auth-service-pg` (k8s-apps), `k8s-docs-pg`,
`ops-agent-pg` (ml), `dove-house-tt-pg` (dove-house-tt), `akan-pg` (akan). Each
gained an `objectstore.yaml` beside its manifest; the Cluster's `backup` block was
replaced by `spec.plugins`, and its ScheduledBackup by `method: plugin`.
`destinationPath` is unchanged throughout, so existing B2 backups stay valid.

`dove-house-tt-pg` was committed to that repo's `staging` branch first, per its
staging-first convention, and promoted to `main` by merge shortly after — its rollout
dropped writes for only ~40s and the old primary drained on its own, no intervention
needed. `dove-house-tt-stg-pg` was deliberately left alone — it has no backup config at
all, which its own manifest comment documents as intentional ("data is
disposable/re-seedable").

All seven are now on the plugin, every ArgoCD Application Synced/Healthy. A second
end-to-end check on dove-house-tt-pg matched akan-pg's: base backup `20260818T105430`
(`backup.info` + 4.75 MB `data.tar.gz`) beside the pre-migration ones in the same path,
and a WAL segment archived at 10:53:05, after its 10:52:35 cutover.

**Three things worth recording, each of which could have silently broken backups:**

1. **`kubectl apply --dry-run=server` gives a false rejection here.** Six of the seven
   clusters failed validation with `Cannot enable a WAL archiver plugin when
   barmanObjectStore is configured` — while being entirely correct. ArgoCD applies with
   Server-Side Apply, so the live objects have no `last-applied-configuration`; a
   client-side apply cannot compute the removal of `spec.backup` and merges the old
   barmanObjectStore back in. Re-running as
   `kubectl apply --server-side --field-manager=argocd-controller --force-conflicts
   --dry-run=server` succeeded on all of them, and inspecting the returned object
   confirmed `spec.backup` genuinely absent and `spec.plugins` present — the atomic
   swap the migration procedure requires. **Had this been taken at face value it would
   have looked like the migration was impossible.**

2. **The plugin needed a new NetworkPolicy, `allow-cnpg-plugin-grpc`.** The operator
   talks gRPC to the plugin on 9090 inside `cnpg-system`, and nothing opened it:
   `allow-cnpg-operator` covers 8080/9443 ingress and app-namespace egress only, over
   `default-deny-all`. The operator logging `Registered plugin` is **not** evidence the
   path works — that step only reads the Service and TLS Secret from the API server;
   the gRPC call happens later, on reconciling a Cluster that uses the plugin. Without
   the rule the plugin would have looked healthy while every cluster failed to archive.

3. **The DR runbook was silently invalidated.** Its restore procedure used
   `externalClusters[].barmanObjectStore`, which is now `externalClusters[].plugin`
   referencing the ObjectStore by name. Also recorded there: `.spec.bootstrap.recovery.
   backup.name` is not supported for plugin-based backups — recovery must go through
   `.spec.bootstrap.recovery.source` plus `externalClusters`.

Four stale `.spec.backup.barmanObjectStore.target` `ignoreDifferences` entries were
also cleared from the immich/ml/dove-house-tt/dove-house-tt-stg ArgoCD Applications.

**pg-main needed three further fixes that the other six did not — all one root cause:
field ownership.** `cnpg-clusters` was the only cluster-owning Application without
`ServerSideApply=true`, so ArgoCD owned `spec.backup` through a managedFields entry with
`operation: Update`. SSA only removes fields its manager previously owned via **Apply**,
so the field survived every attempt and the webhook kept rejecting the result.

The diagnostic contrast that identified this: `immich-postgres` and `auth-service-pg`
both showed `argocd-controller` / `Apply` and migrated with no intervention; `pg-main`
showed `Update` and could not. Check it with:

```sh
kubectl get cluster <c> -n <ns> --show-managed-fields -o json \
  | jq '.metadata.managedFields[] | {manager, operation}'
```

In order, what was needed:

1. `ServerSideApply=true` on the Application — necessary but **not sufficient**, because
   it does not retroactively convert the existing `Update` ownership.
2. `argocd.argoproj.io/compare-options: ServerSideDiff=false`, plus a **hard refresh**
   (`kubectl annotate app cnpg-clusters argocd.argoproj.io/refresh=hard --overwrite`) to
   make the cached comparison re-run. ArgoCD's diff pass dry-runs an apply *without*
   force-conflicts, so it failed the webhook and left the app at `ComparisonError` /
   `Sync: Unknown` — which blocked the sync that would have fixed it. Note the app's
   `operationState` still read "successfully synced (all tasks run)" throughout, so it
   looked healthy unless you read `status.conditions`.
3. Even then the sync itself reported `Cluster/pg-main: SyncFailed` while every sibling
   resource (ObjectStore, ScheduledBackup, PodMonitor) applied fine. **`kubectl apply
   --server-side --force-conflicts` also failed** — force-conflicts resolves conflicts,
   it does not remove `Update`-owned fields. What worked was a single atomic JSON patch
   removing `/spec/backup` and adding `/spec/plugins` in one request, so the webhook only
   ever saw a valid final object:

```sh
kubectl patch cluster pg-main -n cnpg-clusters --type=json -p \
  '[{"op":"remove","path":"/spec/backup"},
    {"op":"add","path":"/spec/plugins","value":[...]}]'
```

   This was a deliberate out-of-band write, run only after git already carried the same
   desired state, so it was a convergence repair rather than drift. ArgoCD reconciled it
   afterwards and now holds the field via Apply, so the `ServerSideDiff=false` annotation
   should be removable at the next opportunity.

**The rollout caused a ~4.5 minute write outage on pg-main.** Switching a Cluster to the
plugin triggers a rolling restart, and the old primary pod — which has no plugin sidecar —
could not archive under the new config (`Error loading plugins, retrying`,
`archive command failed with exit code 1`) and refused to exit. `pg-main-rw` lost all
endpoints, so reads continued via `-ro`/`-r` but writes stopped for authentik, vaultwarden,
nextcloud, infisical, apicurio and uptime-kuma. `smartShutdownTimeout` (180s) did not clear
it; the pod would not have been force-killed until its 1800s grace expired, ~28 minutes.
Resolved with `kubectl delete pod pg-main-5 --grace-period=0 --force` — the PVC persists, so
it restarted on the same data with the sidecar and no promotion was required; writes returned
within ~30 seconds. Five of the six clusters drained on their own; only the busiest stalled.
**Watch `kubectl get endpoints <cluster>-rw` during any future plugin migration.**

**End-to-end verification.** An on-demand `method: plugin` Backup on akan-pg completed in 30s,
and the objects were confirmed present in B2 rather than trusted from the phase — 
`base/20260818T104329/` holding `backup.info` and a 4.25 MB `data.tar.gz`, alongside the
pre-migration backups in the same path, plus WAL segments archived at 10:38 and 10:43, both
after cutover. That verification Backup CR (`akan-pg-plugin-verify`) was left in place; it is
a genuine backup.

**A method warning worth keeping.** The first validation pass used plain
`kubectl apply --dry-run=server` and rejected six of the seven clusters as invalid. They
were all correct — client-side apply cannot compute the removal of `spec.backup` on
SSA-managed objects, so it merged the old `barmanObjectStore` straight back in. Taken at
face value that reads as "this migration is impossible".


### Guardrails added

- **`max_slot_wal_keep_size: "16GB"`** on `pg-main` (`infrastructure/cnpg-clusters/pg-main.yaml`). An abandoned slot is now invalidated rather than allowed to fill a 50Gi volume; the affected replica then needs a re-clone, which is the same 30-second operation performed above. Accepted by the CNPG admission webhook (verified with `kubectl apply --dry-run=server`).
- **Postgres-level alerting, which this cluster had none of** — no PodMonitor in `cnpg-clusters` and no `PrometheusRule` anywhere referencing CNPG or Postgres. Added `infrastructure/monitoring/rules/prometheusrule-cnpg.yaml`: `CNPGWalReceiverDown` (the exact signature of this incident), replication-lag warning/critical, `CNPGTooFewStreamingReplicas`, `CNPGReplicationSlotInactive`, `CNPGReplicationSlotRetainingWAL` (>10 GB, i.e. before `max_slot_wal_keep_size` bites), and `CNPGMetricsDown` so the monitoring is itself monitored. Metric names were read from the operator's own default query set (ConfigMap `cnpg-default-monitoring` in `cnpg-system`) rather than from documentation.
- **A hand-written PodMonitor** (`infrastructure/cnpg-clusters/podmonitor.yaml`) instead of `spec.monitoring.enablePodMonitor: true`. kube-prometheus-stack's Prometheus CR sets `podMonitorSelector: matchLabels: {release: kube-prometheus-stack}`, and CNPG exposes no way to put labels on the PodMonitor it generates (only `podMonitorRelabelings`/`podMonitorMetricRelabelings`, which rewrite scraped samples, not the object's own metadata) — so an operator-generated PodMonitor would have been created and then silently ignored, reproducing the same blind spot the rules are meant to close. `enablePodMonitor` stays `false` so there is exactly one PodMonitor and no duplicate scrapes. The existing `allow-monitoring-scrape` NetworkPolicy in `netpol-cnpg.yaml` already permits `monitoring` → 9187, so no network change was needed.

Both new files were added to their directory `kustomization.yaml` whitelists — omitting that step is the silent-no-op trap already recorded for the ops-agent CiliumNetworkPolicies.

**Unrelated finding:** the server dry-run surfaced a CNPG deprecation warning — native Barman Cloud backup/recovery (`spec.backup.barmanObjectStore`, used by every cluster here) is removed in CloudNativePG 1.31.0. **Actioned the same day** — see the Barman Cloud Plugin migration entry above.

---

## 2026-08-17

### Backblaze B2 silently lost object payloads in both backup buckets

A Velero alert (`nextcloud-default-kopia-maintain-job-*` failed to complete) turned out to be one visible symptom of a **B2 data-integrity problem affecting both backup buckets**. The alert's own suggested remediation — "removing failed job should clear this alert" — was wrong: the job was retrying every 5 minutes and failing identically each time.

**Signature.** B2 returns a valid `list`/`HEAD` — correct size and ETag — then serves **zero bytes** on GET (`IncompleteRead(0 bytes read, N more expected)`). It fails the same way on a 1 KB ranged GET, so it is total payload loss, not truncation. Confirmed non-transient: every affected object failed 3/3 retries. Bucket versioning is Enabled on both buckets, but every affected key had exactly **one** version — there was nothing to roll back to.

**Detection method (read-only, reusable).** Enumerate the bucket, then issue a **1 KB ranged GET per object** — corrupt objects fail even that, so it costs ~26 MB of egress instead of a 215 GB full read. Full-read the small critical blobs (kopia `xn`/`xe`/`xw`/`kopia.*`/`udmrepo`; CNPG `backup.info`) since those are what break repo-open. Two limits worth stating: a ranged probe cannot see corruption *beyond* the first KB, and a readable object can still be silently wrong — only `kopia snapshot verify` checks content hashes. **The counts below are floors, not ceilings.**

**`yanatech-velero` — 21 bad of 25,687.** 17 `_log_` blobs (cosmetic), 3 pack blobs in `kopia/monitoring` (21.0 + 22.4 + 21.0 MB of real backup content, unrecoverable), and 1 index blob in `kopia/nextcloud` — the last of which blocks repo-open, so nextcloud backup *and* restore were broken, not just maintenance. Loss dates spanned 2026-07-23 to 2026-08-15; Velero reported backups `Completed` throughout. Nothing surfaced it until maintenance happened to touch the one object whose loss blocks repo-open.

Since everything in this bucket is reconstructible (Harbor images, Prometheus metrics), it was **wiped and rebuilt** rather than repaired: 120,147 items deleted (108,322 versions + 11,825 delete markers), 278 GB reclaimed, all Velero `Backup`/`PodVolumeBackup`/`BackupRepository` CRs and 69 stale maintenance Jobs removed, then a fresh backup taken immediately rather than waiting for the Sunday schedule — `9026/9026` items, 0 errors, 0 warnings, 23 PVBs Completed, 13 repos re-initialized.

**A `NoncurrentVersionExpiration` lifecycle rule (7 days) was added to `yanatech-velero`, which had none.** Versioning was on with nothing pruning it, so 62.28 GB of dead versions had accumulated since 1 June.

**`yanatech-cnpg` — 37 bad of 21,314, and deliberately NOT wiped.** 24 WAL segments + 13 base-backup files across 6 of 7 clusters (only `akan-pg` clean). Unlike the Velero bucket, nothing here is reconstructible. Crucially the damage is **entirely historical**: every cluster still had an intact base backup from 2026-08-17, and **zero damaged WALs postdate it**, so current recovery capability was never lost. Only the 13 damaged base-backup directories were pruned (38 objects), guarded by an assertion that none was the newest backup for its cluster. The 24 damaged WAL segments were left in place on purpose — deleting them would break the archive chain, and they only affect PITR into windows before the current base backups.

No Backblaze support ticket was raised (deliberate call). Evidence preserved on `kc1`: `/tmp/b2sweep_bad.json`, `/tmp/cnpgsweep_bad.json`, `/tmp/velero-wipe-20260817/velero-crs.yaml`.

### False `ArgoCDWebhookMissing` on shared-services — the check couldn't tell "API down" from "webhook absent"

An `ArgoCDWebhookMissing` (critical) fired for `shared-services`, advising that the webhook be recreated. **The webhook existed and was healthy** — hook `654013140`, created 2026-07-18, `active: true`, correct URL, `content_type: json`, secret set. All 7 repos had theirs, with sequential IDs from the single 18 July batch. Following the alert's own remediation would have created a **duplicate** webhook and double-delivered every push to ArgoCD.

Root cause was in `webhook-delivery-check-cronjob.yaml`:

```sh
hook_id=$(curl -sf ... "/repos/akann/${repo}/hooks" | jq -r '... | .id')
if [ -z "$hook_id" ]; then   # -> ArgoCDWebhookMissing, severity: critical
```

`curl -sf` prints nothing on an HTTP error, and because it's a *pipeline*, `set -e` doesn't catch it — a pipeline's exit status is the last command's, and `jq` succeeds on empty input. So a transient GitHub API error produced an empty `hook_id` and escalated straight to critical. GitHub was mid-incident at the time: a single manual pass had **4 of 7 repos return HTTP 503** (`No server is currently available to service your request`), which is why one arbitrary repo alerted.

Fixed by routing every call through an `api_get()` helper that checks the HTTP status explicitly, requires a JSON array body, and retries 5x with backoff. Persistent API failure now raises **`ArgoCDWebhookCheckFailed` (warning)** with text explicitly warning *not* to recreate the webhook on its strength; `ArgoCDWebhookMissing` (critical) is raised only when the hook list was genuinely fetched and contained no match. The deliveries call got the same guard — a failure there previously yielded an empty list, counted 0 failures and reported healthy, a false *negative* masking real delivery failures. Parsing was unit-tested across six cases (200+array, 200+empty array, 503+error object, 200+non-array, curl-died, multiline JSON); note 200+`[]` still correctly resolves to a genuine `ArgoCDWebhookMissing`.

Same bug class as ops-agent's `list_repo_runners` reporting zero runners for a scale-to-zero ARC set, and as this same alert's sibling in the Velero incident above: **absence of data reported as a confirmed negative, with confidently wrong remediation attached.**

**Also established: zero recent deliveries is not an error.** `shared-services` showed 0 deliveries and `last_response: {"status":"unused"}`, which looks like a webhook that never fired. It isn't — GitHub ages delivery history out within days:

| repo | last push | deliveries | last_response |
| --- | --- | --- | --- |
| shared-services | Aug 2 | 0 | unused |
| yanatech | Aug 2 | 0 | unused |
| dove-house-tt | Aug 16 | 12 | 200 OK |
| ml | Aug 17 | 2 | 200 OK |
| k8s-apps | Aug 17 | 1 | 200 OK |

The two with zero deliveries are exactly the two not pushed since 2 August, and `dove-house-tt`'s oldest retained delivery was only ~1.5 days old. Distinguishing "expired" from "never fired" with certainty would need a test push; the correlation across five repos makes expiry the clear explanation.

### CNPG ScheduledBackup cron was 5-field — five clusters were backing up hourly, not daily

Found while investigating the above. `ScheduledBackup.spec.schedule` is a **6-field** cron (leading seconds), not the 5-field Kubernetes CronJob format. A 5-field `"0 2 * * *"` is silently accepted and parsed as `sec=0 min=2 hour=*` — **hourly at HH:02**. No validation error, no warning.

Five of seven clusters were affected and had been taking hourly base backups for ~30 days:

| Cluster | Was | Now | Base backups retained |
| --- | --- | --- | --- |
| `pg-main` | `"0 2 * * *"` | `"0 0 2 * * *"` | 722 |
| `immich-postgres` | `"0 3 * * *"` | `"0 0 3 * * *"` | 736 |
| `auth-service-pg` | `"0 1 * * *"` | `"0 0 1 * * *"` | 735 |
| `k8s-docs-pg` | `"0 2 * * *"` | `"0 0 2 * * *"` | 735 |
| `ops-agent-pg` | `"0 2 * * *"` | `"0 0 2 * * *"` | 721 |

`akan-pg` (25 base backups) and `dove-house-tt-pg` (31) were already correct — both were written `"0 0 2 * * *"` from the start, which is what made the discrepancy visible. The tell in live state is `lastScheduleTime` landing on the current hour: `kubectl get scheduledbackup -A` showed `17:01`/`17:02`/`17:03` for the five broken ones.

Fixed in `infrastructure/cnpg-clusters/`, `apps/immich/`, `apps/yana-stocks/auth-service/` (this repo) and `k8s/ops-agent/`, `k8s/k8s-docs/` (ml repo), each with an inline comment explaining the field count so it does not regress.

---

## 2026-08-12

### Two stale pve1 mitigations found — one fixed, one blocked by Ceph

Both date from the period when pve1 was crashing Ceph daemons, whose real cause (a failing non-ECC DIMM) was found 2026-07-02 and physically fixed 2026-07-31. Neither had been revisited, and neither was doing what its description claimed.

**1. HA rule comment vs. actual priorities — fixed.** `k8s-cp-affinity` read `comment: K8s control-plane: prefer pve2/pve3, avoid pve1 while crash-prone`, but its `nodes` were `pve1:2,pve2:2,pve3:2` — all equal, i.e. identical in effect to the worker rule labelled "balanced across all nodes". The comment described an intent the rule did not implement, and at a glance it reads like an active safeguard. Corrected live:

```bash
ha-manager rules set node-affinity k8s-cp-affinity \
  --comment 'K8s control-plane VMs, balanced across all three nodes'
```

`proxmox-cluster-setup.md` also documented the old `--nodes "pve2:2,pve3:2,pve1:1"` form as current; updated to match live state.

**2. `disallowed_leaders pve1` — still set, still inert, could not be cleared.** `ceph mon dump` shows `election_strategy: 1` (classic) with `disallowed_leaders pve1`. Classic never consults that list — only `disallow` (2) and `connectivity` (3) do — so it has done nothing since the election strategy was reverted, and pve1 is in fact the current mon leader.

Attempting the obvious cleanup fails:

```
$ ceph mon rm disallowed_leader pve1
Error EINVAL: You cannot disallow monitors in your current election mode
```

The mode guard applies to removal as well as addition. Clearing it therefore needs `set election_strategy 2` → `rm disallowed_leader pve1` → `set election_strategy 1`, and each strategy change forces a mon re-election — brief, but it blocks RBD clients (i.e. every VM disk and PVC) for the duration. Not worth it for a dormant flag, so it is **left in place deliberately**.

**Why it still matters:** the entry is inert by circumstance, not by design. It arms itself the moment the election strategy changes for any unrelated reason, silently barring pve1 from leadership over a hardware fault that no longer exists — and nothing would connect the two events. Actioned as: remove it as part of any future election-strategy change (e.g. the pending move to `connectivity` after a 19.2.4+ upgrade). Recorded in `proxmox-cluster-setup.md` § Mon Leader Management.

**Also corrected in that section:** the 2026-06-23 root-cause analysis (Ceph 19.2.3 MonitorDBStore/BlueStore bugs) was still presented as the explanation for the crash spree. It is retained as the reason the crashes took the form they did, but is now explicitly marked superseded by the 2026-07-02 memtest verdict.

---

## 2026-08-04 (later)

### Worker node disk pressure — unbounded GHCR image tag accumulation (immediate fix only, root cause open)

**Alert:** `k8s-worker-1` (192.168.33.31) at 83% disk (18G free of 96G). Checking the other 2 workers showed this was fleet-wide, not isolated: worker-2 at 71%, worker-3 at 74% — worker-1 was just the one that crossed first.

**Root cause:** `du` showed 71G of worker-1's 79G in `/var/lib/containerd`. Grouping `crictl images` by repository named it precisely: `ghcr.io/akann/dove-house-tt-migrate` (36 tags, 12.74GB) and `ghcr.io/akann/dove-house-tt` (36 tags, 2.83GB) — every `yana-stocks` image on Harbor showed only 1-2 tags each, because Harbor has the automated retention/GC CronJobs documented above (2026-07-26). GHCR — used by `dove-house-tt` and `akan`, both tagged by commit SHA every CI push — has **no equivalent**, so every historical tag any node ever pulled just accumulates on that node's disk forever.

**Immediate fix:** `crictl rmi --prune` on all 3 workers (removes only images with zero current container references — safe, and anything pruned just re-pulls on next use). First pass with the default 2s per-image gRPC timeout logged `DeadlineExceeded` on most removals and looked like it did nothing — misleading: `df` was racing ahead of containerd's async snapshotter cleanup, not a failed prune. A `-t 60s` second pass confirmed zero remaining prunable images and the real numbers: worker-1 79G→55G (83%→58%, 18G→41G free), worker-2 68G→57G, worker-3 71G→58G. Image count on worker-1 dropped 203→66.

**Not fixed — needs a decision:** nothing prevents this from re-accumulating. Options considered but not built without checking in first, since either needs new automation and/or a new credential (same class of decision as the `argocd-webhook-delivery-check` GitHub PAT, 2026-07-18):
1. A GHCR-side retention CronJob mirroring Harbor's `harbor-enforce-retention-policy` pattern — needs a new fine-grained GitHub PAT (`packages:delete` on the `dove-house-tt`/`akan` packages) created manually via GitHub's UI, same as every prior narrowly-scoped PAT in this repo.
2. Lowering kubelet's image-GC thresholds (default high/low watermark is 85%/80%, so this alert fired just *below* where kubelet's own automatic GC would have started reclaiming on its own) — a kubelet-config + static-pod change across all 3 workers, not tracked in this repo, same category as the scheduler/controller-manager/etcd metrics-bind-address changes noted above.
3. Do nothing further and re-run the manual prune next time this alerts.

**Follow-up, same day:** option 1 was chosen. Added
`infrastructure/argocd/ghcr-retention-cronjob.yaml` +
`external-secret-ghcr-retention.yaml` — see `CLAUDE.md`'s GHCR image tag
retention entry for the full design (two-factor retention: outside the 10
most-recent AND older than 14 days, to protect a low-traffic environment like
`dove-house-tt-stg` from a pure rank-based cutoff). Verified the retention jq
logic against two synthetic scenarios before trusting it against real data: 15
versions spread over 42 days correctly kept the newest 10 and deleted the 5
past both cutoffs; a 12-version rapid-push burst (all within 2 days) correctly
deleted nothing, since the 2 outside the top-10 were still under the 14-day
floor. **Not yet functional** — needs a new fine-grained GitHub PAT
(`Packages: Read and write`, scoped to `dove-house-tt`+`akan`) created
manually via GitHub's UI and added to Infisical as
`/argocd/GITHUB_GHCR_RETENTION_TOKEN`; the CronJob will fail auth until that
secret exists.

**Follow-up, same day — token added, two real bugs found and fixed doing the
end-to-end verification:**

1. **Fine-grained PATs don't have a `Packages` permission at all.** Checked
   both the Repository- and Account-permission lists in GitHub's fine-grained
   token UI directly (scrolled the full alphabetical list of each, not just
   searched) — genuinely absent from both, not a UI quirk. Classic PAT with
   `read:packages` + `delete:packages` used instead. Trade-off: unlike
   fine-grained, a classic token's scope can't be limited to just
   `dove-house-tt`/`akan` — it applies to all of the account's packages.
   Accepted as reasonable for a personal account with 3 packages total.
2. **The CronJob only ever looked at page 1.** A first manual test run (37
   deletions on `dove-house-tt-migrate`) succeeded but looked suspiciously
   like it was leaving most of the junk untouched. Checked directly against
   GitHub: `dove-house-tt` had 518 versions, `dove-house-tt-migrate` 221,
   `akan` 202 — the job's `per_page=100` with no pagination meant it had
   never seen anything past the newest ~100 pushes on any package, since the
   day it was written. Fixed with a real pagination loop (capped at 50 pages
   as a backstop, not an expected ceiling) — see `[[ghcr-retention-cronjob]]`
   commit for detail. Hit a second bug fixing the first: passing the growing
   version array through `jq --argjson` blew past the shell's ARG_MAX
   (`Argument list too long`) once it exceeded page 1 — the exact bug class
   `ml`'s k8s-docs ingest workflow already hit and documented above
   (2026-07-16). Same fix: route the array through a file instead of argv.

**Verified before trusting a live mass-delete:** confirmed GitHub returns
each page strictly newest-first and that ordering survives concatenation
across pages (page N's oldest entry is always newer than page N+1's newest
— checked directly, not assumed); extracted the literal script from the
committed manifest via YAML parsing (not copy-paste, so no risk of testing a
diverged copy) and ran it with the DELETE calls stubbed to `echo`, getting
392/158/98 — proportional, no red flags like near-100% or near-0% deletion.
Then ran it for real from the actual cluster-synced CronJob (not a scratch
copy). All 648 deletes succeeded (a single `curl -sf` failure under `set -e`
would have aborted the whole job). Re-queried GitHub fresh afterward:
`dove-house-tt` 518→126, `dove-house-tt-migrate` 221→63, `akan` 202→104 —
each landed exactly on the precomputed "would keep" number.

**Follow-up, same day — a fourth package was missing.** Asked directly why
only `akan`/`dove-house-tt` were covered, which surfaced that the job's
`packages="dove-house-tt dove-house-tt-migrate akan"` list was hardcoded and
had simply never included `yanatech` — it also publishes to GHCR
(`ghcr.io/akann/yanatech`), and nothing in this repo's docs ever stated
that, so it was invisible until checked directly against GitHub's API
(`GET /users/akann/packages?package_type=container` — 4 packages, not 3).
Fixed the actual design flaw, not just the missing entry: the package list
is now **discovered live** via that same endpoint every run, so this can't
silently drift out of sync again the next time a repo starts publishing to
GHCR. Verified with the same dry-run-then-real-run discipline as above:
discovery correctly found all 4 packages, `akan`/`dove-house-tt`/
`dove-house-tt-migrate` correctly showed 0 further deletions (consistent
with having just been cleaned), `yanatech` showed 43 versions with 33
flagged for deletion (its first-ever cleanup) — ran for real, succeeded.

## 2026-08-04

### 9 Prometheus scrape targets had been down for their entire history — NetworkPolicy ingress gaps, not broken components

**Context:** an `ops-agent` health check reported `Observability — DEGRADED`: 9 unreachable scrape targets and 7 `TargetDown` alerts firing. Every one of them had `avg_over_time(up[7d]) == 0` — these were never intermittent, they had simply never scraped successfully since the policies that block them were written. Two `TargetDown` fixes had already landed earlier the same day (`ce520df`, `1a4b4cf`, for scheduler/controller-manager/etcd); this is the rest of the set.

**Diagnosis:** every failure surfaced identically as `context deadline exceeded`, which is what a silent Cilium drop looks like to a scraper — misleadingly like a slow or hung endpoint. A live `hubble observe` on `k8s-worker-1` (Prometheus's node) gave the actual verdict: `policy-verdict:none INGRESS DENIED → DROPPED (TCP Flags: SYN)`. The drop is at the **destination** pod, not on Prometheus's egress — `allow-prometheus-egress` is already unrestricted, so `monitoring`'s `default-deny-all` catching the inbound side was the whole story. No component was actually unhealthy.

**Change — 6 in-cluster targets** (`infrastructure/network-policies/netpol-monitoring.yaml`, `netpol-argocd.yaml`):

| Target | Port | Gap |
|---|---|---|
| kube-state-metrics | 8080 | no policy selected the pod at all → new `allow-kube-state-metrics-ingress` |
| prometheus-operator | 10250 | no policy selected the pod at all → new `allow-prometheus-operator-ingress` |
| grafana | 3000 | `allow-grafana-ingress` permitted only `ingress-nginx` |
| tempo | 3200 | `allow-tempo-ingress` permitted only `app.kubernetes.io/name=grafana` |
| alertmanager | 8080 | `allow-alertmanager-ingress` permitted only 9093 (the config-reloader's `/metrics` is a *second*, separate target — its 9093 target was up the whole time, which is why this looked half-working) |
| argocd-application-controller | 8082 | `argocd`'s `allow-argocd-internal` permits only the `argocd` namespace → new `allow-monitoring-argocd-metrics` |

The two brand-new policies are an instance of Network Policies rule 7 in reverse: `default-deny-all` had already flipped these pods to deny-by-default, and nothing was ever written to allow the scrape back in.

**Change — 3 Ceph MGR exporters** (`192.168.22.11-13:9283`, `infrastructure/cilium/ciliumnetpol-pve-scrape.yaml`): `allow-prometheus-to-pve-exporters` listed only ports 9100 and 9221; 9283 was never added. **Two independent blocks, both required** — the Cilium fix alone is not sufficient:

1. *(fixed here)* the CNP now includes 9283.
2. *(NOT fixed here — needs a manual pfSense change)* APP_VLAN(33) → PMX_VLAN(22) doesn't permit 9283. From `k8s-cp-1` (192.168.33.21), ports 9100/9221/8006 to all three PVE nodes are OPEN while 9283 is FILTERED. `pve-firewall` is **not** the blocker: `/etc/pve/nodes/pve1/host.fw` and the live `PVEFW-HOST-IN` chain both already accept `192.168.33.0/24 → 9283`. Almost certainly a gap left by the 2026-07-14 segmentation hardening. The exporter itself is healthy — `ceph mgr module ls` shows `prometheus on`, `ceph-mgr` listens on `*:9283`, and `curl localhost:9283/metrics` returns 200 on pve1.

**Separately noted, not addressed here:** `metrics-server` is not installed in any namespace, so `kubectl top` and the Metrics API return `Metrics API not available` cluster-wide. Goldilocks is deployed and normally depends on it. Not part of the 9 down targets; left as a follow-up.

**What the restored visibility then exposed:** with `kube-state-metrics` scrapeable again for the first time, three `KubeJobFailed` alerts and a `KubePodNotReady`/`KubeContainerWaiting` pair went pending — none of them new problems, just newly *visible* ones. The three failed Jobs are long-dead one-offs whose successors all succeed: `kube-system/descheduler-29697840` (46d, CronJob-owned, recent runs all Complete — **deleted**, it was a retained `failedJobsHistory` entry with no pods left), `minio/minio-post-job` (19d) and `monitoring/kube-prometheus-stack-crds-upgrade` (36d). The latter two are **deliberately left in place**: both carry an `argocd.argoproj.io/tracking-id` and are Helm hooks, so deleting them flips their Application `OutOfSync` and invites selfHeal to recreate a Job that may just fail again — the alert is cosmetic, a delete would be the riskier move. The actions-runner pod was `runners-k8s-apps-...-listener` cycling normally on this very push (ARC ephemeral runners).

### metrics-server installed — the cluster had no Metrics API at all

`kubectl top` returned `Metrics API not available` cluster-wide and `kubectl get apiservice v1beta1.metrics.k8s.io` was `NotFound` — this was never installed, not broken (no trace of it anywhere in this repo's git history). Goldilocks has been deployed since wave 5 without the metrics source it normally depends on.

Added `infrastructure/metrics-server/argocd-app-metrics-server.yaml` (chart 3.13.1 / app 0.8.1, wave 3, `kube-system`), registered in the root `kustomization.yaml`. Three decisions worth recording:

- **`--kubelet-insecure-tls` is required here.** kubeadm did not enable `serverTLSBootstrap` on this cluster — `kubelet-config` carries only `rotateCertificates: true` (that's kubelet *client* certs) and `kubectl get csr` is empty, so no kubelet serving CSR was ever issued. Kubelet presents a self-signed serving cert the cluster CA can't verify, and every scrape would fail x509 without this flag. Enabling `serverTLSBootstrap` instead would mean a kubelet-config + static-pod change across all 6 nodes that isn't tracked in this repo — deliberately not taken.
- **2 replicas + PDB + `required` anti-affinity.** kured reboots nodes on this cluster; a single replica would blank the Metrics API each time. The anti-affinity is `required` rather than `preferred` because with 6 nodes there's no scheduling pressure, and co-scheduling both replicas would silently defeat the second one.
- **No CPU limit, deliberately.** metrics-server is a bursty scrape loop — exactly the shape that produced the permanently-firing `CPUThrottlingHigh` on mongodb's exporter fixed in this same batch (below). Chart-default requests only, which is also the chart's own default posture.

`metrics.enabled` + `serviceMonitor.enabled` are on with the `release: kube-prometheus-stack` label, so it self-monitors like the rest of the stack. `kube-system` has **no** NetworkPolicies at all, so nothing had to be opened — and per Network Policies rule 7, nothing should be *added* there either: the first policy to select a pod in that namespace would flip everything else in `kube-system` to default-deny.

**Watch item:** the aggregated APIService path is kube-apiserver → the metrics-server **ClusterIP** (`--enable-aggregator-routing` is unset on this cluster's apiserver, so it dials the ClusterIP rather than the endpoint IP). That is the same path this cluster's known Cilium-native-routing latency affects — the reason ESO's webhook is disabled and all three Kong webhooks are pinned to `timeoutSeconds: 5`. Measured after install: see below.

### MongoDB exporter sidecar — CPUThrottlingHigh was a quota artifact, not CPU starvation

Firing on both `mongodb-0` and `mongodb-1` for the `metrics` (mongodb_exporter) container. Measured before changing anything: **~3.7 millicores average, ~4.4m peak over 6h — about 2.5% of its 150m limit — while 33-37% of CFS periods were throttled.** That gap is the low-limit + bursty-workload artifact, not a starved container: the exporter does all its work in a short burst per scrape and exhausts its tiny per-100ms quota slice inside that burst.

Raised the CPU limit 150m → 500m in `infrastructure/mongodb/argocd-app-mongodb.yaml` (`metrics.resources`), which widens the per-period slice; the request drops 100m → 25m since limits aren't reservations and 100m was over-reserving ~27x measured usage. Memory (128Mi/192Mi, peak working set ~52MiB/24h) and ephemeral-storage are restated **unchanged** — `resourcesPreset: "none"` is required for an explicit `resources` block to win over the chart's `nano` preset, and it drops *every* preset-supplied value, not just the cpu ones, so anything not restated would silently disappear. Applying this rolls the MongoDB StatefulSet (replica set failover, arbiter present).

## 2026-08-02

### Sentry disabled everywhere except yana-stocks (free-tier quota conservation)

**Context:** the workspace is on Sentry's free tier; with 15 services across 6 repos all reporting, quota was being spread thin for no real benefit outside the one production system (`yana-stocks`) that actually needs error tracking day to day.

**Change:** added a new, explicit `SENTRY_ENABLED` (`NEXT_PUBLIC_SENTRY_ENABLED` for the 3 Next.js apps, build-time-inlined) env var to every non-yana-stocks Sentry integration, defaulting `"false"`, gating `Sentry.init`/`withSentryConfig`/the NestJS `SentryModule.forRoot()`+`SentryGlobalFilter` wiring. Disabled: `yanatech`, `akan`, `dove-house-tt` (both `main` and `staging`), `shared-services`' `email-api`/`email-service`, `ml`'s `k8s-docs`/`ops-agent`. `yana-stocks` (all 9 of its Sentry-integrated services) is untouched and stays fully enabled — it also only has a production environment, so no separate prod/staging split was needed there.

Deliberately **not** a secrets change — every DSN stays wired exactly as before in Infisical/CI, so re-enabling any repo later is a one-line flip of `SENTRY_ENABLED`/`NEXT_PUBLIC_SENTRY_ENABLED` back to `"true"` in that repo's CI workflow build-args and/or k8s `deployment.yaml`, with no DSN to look up or re-enter. `shared-services`/`ml`'s separate CI "Upload source maps to Sentry" steps (which call `@sentry/cli` directly, independent of the app-level flag) were also gated off (`if: false`) so CI stops making Sentry API calls for those two repos.

Also corrected `README.md`'s §11.3.1 Sentry Alerting section, which undercounted the integrated-service list as 11 — it was actually missing yana-stocks' `auth-service`, `price-ingestor`, `sentiment-analyzer`, `ml-predictor`, and `ml/ops-agent` (15 total), found while mapping out this change.

**Verified before considering this done:** `pnpm build` for all 3 Next.js apps with the flag unset — succeeded, no Sentry sourcemap-upload output. `pnpm turbo lint/type-check/test` for `shared-services` (both apps) and `ml/k8s-docs` — all green, confirming the conditional NestJS module array doesn't break Nest's DI graph. `ops-agent`'s `mypy`/`ruff`/`pytest` (203 tests) — all green. No changes made to `yana-stocks`.

## 2026-07-31

### New alerting for yana-stocks' external-API reliability (circuit breakers added in the `yana-stocks` repo)

**Context:** a code-review comment asked how `portfolio-api`/`price-processor`/`sentiment-analyzer` handle third-party outages (FMP, Massive/Polygon, Twelve Data) — investigation found solid timeout/fallback-cache behavior already, but zero metrics of any kind for external-API failures anywhere (only generic inbound `http_requests_total`), confirmed against a real past incident (FMP silently deprecated an endpoint; the failure was only ever visible as a `WARNING` log line). Fixed in `yana-stocks` by wrapping every FMP/Massive/Twelve Data call site in a per-provider circuit breaker (`opossum` in the two Node services, `pybreaker` in `sentiment-analyzer`) whose success/failure/open/close events emit two new same-named metrics across all three services: `external_api_requests_total{provider,outcome}` and `external_api_circuit_state{provider}` (0=closed/0.5=half-open/1=open).

**Change here:** new `PrometheusRule` (`infrastructure/monitoring/rules/prometheusrule-yana-stocks-external-apis.yaml`, added to that directory's `kustomization.yaml`):

- `ExternalApiCircuitOpen` — `external_api_circuit_state{job=~"portfolio-api|price-processor|sentiment-analyzer"} == 1` for 5m, `severity: warning`.
- `MassiveFeedSilent` — `rate(bars_published_total[15m]) == 0` for 15m, `severity: warning`. Reuses `price-ingestor`'s pre-existing counter — no new instrumentation needed for this one.

Also added a new Alertmanager `time_intervals` entry (`nyse-trading-hours`, `location: America/New_York`, Mon-Fri 09:30-16:00 — IANA timezone, so DST is handled automatically, unlike the frontend's own manual-UTC-offset market-hours check) and a child route matching `alertname = "MassiveFeedSilent"` with `active_time_intervals: [nyse-trading-hours]`, so the price feed going quiet overnight/weekends (expected) doesn't page anyone — `ExternalApiCircuitOpen` gets no such restriction, since a third-party API being down is meaningful at any hour. Both changes live in `argocd-app-monitoring.yaml`'s inline Helm `values:` block.

**Verified before considering this done:** `kubectl kustomize infrastructure/monitoring/rules` builds cleanly with the new rule included (confirms the kustomization-whitelist gotcha this repo has hit before wasn't repeated); the embedded Alertmanager `values:` YAML block was separately parsed out and validated (a plain top-level YAML parse of the outer file does *not* recursively validate a literal block-scalar string's contents).

## 2026-07-24

### `stocks.portfolio.events` removed — producer-only topic with no consumer

**Context:** the topic was produced by `portfolio-service` (on portfolio creation and add-stock) but consumed by nothing anywhere — verified 2026-07-23 during the KafkaTopic-name audit, and previously documented in both repos' CLAUDE.md as an honest gap ("an event stream into the void") rather than a feature.

**Change:** removed end to end rather than left in place. In `yana-stocks` (commit `d8163aa`): the whole `KafkaProducerService` (its only method was `emitPortfolioEvent`), both emit call sites, the `CurrentUser` param decorator that existed solely to stamp `userId` on those events, the `PortfolioEventType`/`PortfolioEventMessage` shared types, the `PORTFOLIO_EVENTS` constant in `kafka-client`, and every producer mock in the specs — `portfolio-service` is now Kafka consume-only (`stocks.prices.processed`). Here: the `stocks.portfolio.events` `KafkaTopic` deleted from `apps/kafka/yana-stocks-topics.yaml` — Strimzi's topic operator drops the live broker topic (and its ~30d of unread retained events, which nothing ever read) when ArgoCD prunes the CR. Docs updated in both repos plus the akan blog post that described the gap.

**Why now:** the topic cost nothing to keep, but it was the workspace's one remaining "wired at the infra layer, never finished in code" artifact (same shape as `portfolio-service`'s phantom `users.registered` KEDA trigger removed 2026-07-23), and nothing on the roadmap consumes it — removing it is one small commit per repo; re-adding it later is the same.

## 2026-07-23

### akan's first CNPG cluster (`akan-pg`) — 4-part NetworkPolicy gap for a CNPG cluster hosted in an app's own namespace (not `cnpg-clusters`)

**Context:** `akan` shipped blog comments + star ratings, its first feature needing a database — a new dedicated `akan-pg` CNPG cluster living in the `akan` namespace itself (unlike `pg-main`/`k8s-docs-pg`/`dove-house-tt-pg`, which each get and are the sole occupant of their own namespace, but are still architecturally "a CNPG cluster as the only tenant of a namespace" — `akan-pg` is the first case of a CNPG cluster sharing a namespace with an existing, already-deployed application). `akan`'s NetworkPolicy had only ever needed DNS + HTTPS (Turnstile, Sentry, email-api) egress — nothing had opened a path for a database.

**Symptom:** deploying the CNPG cluster + the app's new migrate initContainer produced two simultaneous, independently-diagnosed failures: the migrate initContainer crash-looped with `connect EPERM` against the `akan-pg-rw` ClusterIP, and CNPG's own `cnpg-cloudnative-pg` operator logged `Instance Status Extraction Error: HTTP communication issue` / `dial tcp <pod-ip>:8000: i/o timeout` trying to reach the instance pod directly, and the CNPG instance manager's own `initdb` job separately timed out reaching the kube-apiserver (`dial tcp 10.96.0.1:443: i/o timeout`).

**Root cause — 4 separate missing rules, found and fixed in 2 passes:**
1. `allow-akan` (`netpol-infrastructure.yaml`) had no egress rule for port 5432 at all.
2. `netpol-apiserver-egress.yaml` had no `allow-kube-apiserver-egress` entry for the `akan` namespace — CNPG's instance manager watches its own `Cluster` CR via the apiserver, same as the pre-existing `k8s-docs`/`dove-house-tt` entries there.
3. `netpol-cnpg.yaml`'s `allow-cnpg-operator` (in `cnpg-system`) has a **per-namespace egress allowlist** (documented as `CLAUDE.md` Network Policies rule 8) — `akan` was never added.
4. **The one that actually mattered, found last:** `akan-pg`'s own **ingress** side had no rule at all. Every existing CNPG-hosting namespace (see `yana-stocks`' `auth-service-pg`) gets a dedicated `allow-cnpg-operator` NetworkPolicy scoped via `podSelector: {cnpg.io/cluster: <name>}` (ingress from `cnpg-system` on 8000/5432/9187) **plus** an `allow-intra-namespace` policy (bare `podSelector: {}`, ingress+egress from/to `podSelector: {}`) so the app's own pods can reach the DB pod. Fixes 1-3 only ever opened *egress* paths **toward** `akan`/`akan-pg` from elsewhere — nothing had ever opened *ingress* **into** the new `akan-pg-1`/`akan-pg-2` pods, which fixes 1-3 alone can never fix no matter how long you wait (confirmed by polling the cluster phase for 5+ minutes with zero change after fixes 1-3 landed and synced).

**Diagnosis method, not just guessing:** confirmed both original symptoms were genuine Cilium policy denies (not a propagation delay, not an app bug) by triggering a live connection attempt from a running `akan` pod while tailing `hubble observe` on the node's Cilium agent pod — `ETIMEDOUT` on a direct pod-IP target vs. the app's own instant `EPERM` on the ClusterIP target are two different Cilium enforcement paths (packet-level drop vs. synchronous sockops-level reject for service-routed traffic), both consistent with policy denial, not a code or DNS problem.

**Fix:** two commits. First added the 3 egress-side rules above (`netpol-infrastructure.yaml` + `netpol-apiserver-egress.yaml` + `netpol-cnpg.yaml`). Confirmed via `kubectl` that ArgoCD synced all three within seconds, but the cluster phase stayed stuck on the extraction error for 5+ minutes — that's what triggered the deeper Hubble-based investigation that found gap 4. Second commit added `akan`'s own `allow-cnpg-operator` (podSelector on `cnpg.io/cluster: akan-pg`) + `allow-intra-namespace` to `netpol-infrastructure.yaml`, mirroring `yana-stocks` exactly. Cluster phase went `Instance Status Extraction Error` → `Creating a new replica` → `Waiting for the instances to become active` → `Cluster in healthy state` within ~90 seconds of that second commit syncing. Migrate initContainer succeeded on its next retry, deployment rolled out, and the live site (`akan.nkweini.org/blog/*`) was confirmed serving real DB-backed ratings/comments end-to-end.

**Key lesson for the next app that gets its own CNPG cluster inside an existing app's namespace** (rather than a namespace created fresh alongside its CNPG cluster, like `k8s-docs`/`dove-house-tt`): that existing namespace's `NetworkPolicy` almost certainly predates any database need and won't have the CNPG-cluster's own ingress side covered — don't assume `k8s-docs`/`dove-house-tt`'s already-correct manifests (created namespace + CNPG cluster together from day one) are a complete checklist; the `yana-stocks`/`auth-service-pg` pattern (`allow-cnpg-operator` scoped by `cnpg.io/cluster` + `allow-intra-namespace`) is the one that generalizes to "adding a CNPG cluster to an already-existing namespace." See `CLAUDE.md`'s Network Policies section (rule 8 and the "Adding a new namespace" checklist) for the updated guidance.

## 2026-07-18

### `bootstrap.sh` drift fixed + CNPG Postgres backups moved off-cluster to B2

**Context:** a full-cluster-rebuild readiness review found two gaps.

**Gap 1 — `bootstrap.sh` had drifted from `kustomization.yaml`.** This repo's own checklist (`docs/argocd-explained.md`) says every new app needs a line in both files; that hadn't been followed for the last several additions. `bootstrap.sh` was missing `apps/akan`, `apps/shared-services`, `apps/ml`, `apps/dove-house-tt`, `apps/dove-house-tt-stg`, and infra apps `minio`, `cilium-policies`, `harbor-backup`, `grafana-dashboards`, `monitoring-rules`, `actions-runner-apps`, `runners-shared-services`, `runners-ml` — on a real fresh-cluster bootstrap none of these would have deployed. Its manual-secrets header also predated the 4 private-repo apps and never documented the `repo-akan`/`repo-shared-services`/`repo-ml`/`repo-dove-house-tt` git-credential Secrets or dove-house-tt's `ghcr-secret`, without which those apps fail with `Repository not found` / image pull errors on a fresh cluster. **Fix:** rewrote `bootstrap.sh`'s apply sequence to mirror `kustomization.yaml` exactly (verified via diff — every file in the kustomization is now applied) and documented the missing manual secrets in the header.

**Gap 2 — CNPG Postgres backups had no off-cluster copy.** `pg-main`, `immich-postgres`, and `auth-service-pg` all streamed barman WAL/backups to in-cluster MinIO, which itself sits on Ceph RBD. The only actual off-cluster backup target (Velero → Backblaze B2) deliberately excludes CNPG PGDATA (2026-07-16 fix, see above — a live Kopia fs-backup of a running PGDATA dir has no consistency guarantee). Net effect: a Ceph loss alongside a k8s rebuild would have taken every Postgres backup down with it, with nothing recoverable — including Vaultwarden's own database, which this repo's bootstrap process treats as the "source of truth" for the cluster's manual bootstrap secrets. **Fix:** repointed all three visible CNPG clusters' `barmanObjectStore` from MinIO to the same Backblaze B2 account Velero uses. Each namespace gets its own `cnpg-b2-credentials` ExternalSecret (`external-secret-b2.yaml`) pulling from Infisical `/cnpg-clusters/ACCESS_KEY_ID` + `/cnpg-clusters/ACCESS_SECRET_KEY` — the cnpg-clusters namespace's copy of this ExternalSecret already existed from an earlier bulk-scaffolding commit but was never wired into `pg-main`'s Cluster spec.

**Verified live via SSH to `k8s-cp-1` before finalizing:**
- The Infisical values already existed and `cnpg-b2-credentials` was already `SecretSynced: True` in the `cnpg-clusters` namespace (from that earlier scaffolding commit).
- The bucket name guessed initially (`yanatech-cnpg-backups`) doesn't exist — the real bucket is **`yanatech-cnpg`** (confirmed against the account's actual bucket list: `yanatech-cnpg`, `yanatech-pg`, `yanatech-proxmox`, `yanatech-velero`). All three Cluster manifests use `s3://yanatech-cnpg/<cluster-name>`.
- Read/write/delete access confirmed with a throwaway debug pod (`amazon/aws-cli` image, deleted after) — `head-bucket`, `ls`, and a `cp`+`rm` round-trip all succeeded with the synced credentials.
- The bucket already contained ~1350 objects under `pg-main/` dated 2026-06-04 through 2026-06-08, then nothing — an earlier, apparently-abandoned attempt at this same migration. Left in place (not deleted); `immich-postgres` and `auth-service-pg` had no prior data there.

**Still open:**
- `k8s-docs-pg` (ml repo) and `dove-house-tt-pg` (dove-house-tt repo) still point at MinIO — same fix needed in their own repos.
- Retention on the new B2 destination is still `retentionPolicy: 7d`, unchanged from the MinIO setup — worth reconsidering now that it's the sole backup copy rather than a local convenience copy.
- Haven't yet confirmed CNPG successfully starts a fresh backup chain in `yanatech-cnpg/pg-main/` after re-pointing (vs. getting confused by the old abandoned timeline sitting there) — check `kubectl get backups.velero.io` equivalent for CNPG (`kubectl get backup -n cnpg-clusters`) and the next `ScheduledBackup` run once this is pushed and synced.

---

## 2026-07-16

### Velero weekly backups fixed — root cause was opt-out fs-backup sweeping up Velero's own maintenance jobs

**Symptom:** the last 3 consecutive `velero-weekly-backup` runs came back `PartiallyFailed` (18 errors → 14 errors/8 warnings → 7 errors/132 warnings), even though the Backblaze B2 `BackupStorageLocation` itself was healthy the whole time.

**Root cause:** the Schedule used `defaultVolumesToFsBackup: true` (opt-out) — Velero tried to Kopia-backup *every* volume on *every* pod cluster-wide, no exceptions possible. That swept up things nobody intended to back up:
- **126 of 132 warnings** ("Skip pod volume scratch/plugins") were Velero's *own* internal `<namespace>-default-kopia-maintain-job-*` repository-maintenance Job pods — created by Velero itself roughly every 66 minutes per namespace, not something this repo can annotate to exclude.
- **5-7 errors per run** were a genuine race: those same ephemeral pods (plus `argocd-repo-server`/`argocd-applicationset-controller` scratch volumes) got torn down before Velero's node-agent could expose their volume for snapshotting — `context deadline exceeded` / `etcd timed out` / volume path not found.

Diagnosed via `kubectl get backups.velero.io -o custom-columns=...` for the error/warning trend, `kubectl get podvolumebackups.velero.io -l velero.io/backup-name=<name>` for per-item failures, and `kubectl exec deploy/velero -- /velero backup logs <name>` (the velero image ships the CLI binary too) for the full warning breakdown once pod logs had rotated past the run.

**Fix:** flipped to opt-in fs-backup (`defaultVolumesToFsBackup: false` in `infrastructure/velero/argocd-app-velero.yaml`) and added an explicit `backup.velero.io/backup-volumes: <volname>` pod annotation to every workload that actually holds real PVC data (gotify, uptime-kuma, vaultwarden, harbor's 5 internal components, infisical's bundled redis, kafka, minio, mongodb, prometheus, alertmanager, loki, tempo, nextcloud, pgadmin, standalone redis). Verified each chart's actual annotation key via `helm show values`/template inspection on the live cluster rather than guessing — several charts nest it differently than expected (e.g. Harbor's `database.podAnnotations`/`redis.podAnnotations` are direct children, *not* nested under `.internal`; kube-prometheus-stack uses `podMetadata: {annotations: {...}}`, not `podAnnotations`).

**Deliberate scope decision:** CNPG Postgres clusters (`pg-main`, `auth-service-pg`, `k8s-docs-pg`, `dove-house-tt-pg`, `dove-house-tt-stg-pg`, `ops-agent-pg`) were **not** given the opt-in annotation — they were being fs-backed-up under the old opt-out mode, but a live Kopia copy of a running PGDATA directory with no `pg_backup_start`/`stop` bracketing has no consistency guarantee, unlike CNPG's own barman WAL-streaming backup which already provides clean PITR for all of them. Dropping this was a correctness fix, not just a coverage preservation — see CLAUDE.md's Backup Strategy section for the full writeup.

**Follow-up, 2026-08-05 — this fix reduced but did not eliminate `PartiallyFailed` runs.** `docs/storage-and-backup-architecture.md` previously (incorrectly) said this was fully resolved in one place and "root cause not yet isolated" in another — both were stale. Live state as of 2026-08-05: 2026-07-26 came back `Completed`, but 2026-08-02 was `PartiallyFailed` again (1 error, down from the double digits above — this fix did help). Confirmed via `kubectl describe podvolumebackups.velero.io -n velero -l velero.io/backup-name=velero-weekly-backup-20260802020011` and the `velero` pod's logs that the remaining failure is a **different** cause than the one above: an etcd leader-change race during the Sunday 02:00 UTC window itself (`error to get PVB ...: etcdserver: leader changed`), not fs-backup scope. Not yet root-caused further. Alerting was added instead so this doesn't silently recur unnoticed (`infrastructure/monitoring/rules/prometheusrule-velero.yaml`).

### ingest-docs CI broken by the Velero fix commit's own doc changes — argv length limit

The commit above touched `CLAUDE.md` (46KB) and `README.md` (55KB) in the same push, and the `Ingest Docs` workflow that feeds the k8s-docs RAG chatbot failed: `jq: Argument list too long` (exit 126). Its payload-assembly script passed full file contents through `jq --arg`/`--argjson` and the final POST through `curl -d "$PAYLOAD"` — all of these route their value through the process's argv, which has a per-argument ceiling around 128KB regardless of the shell's overall `ARG_MAX`. The combined `files` JSON for this push was 164KB, comfortably over that line.

Fixed by rerouting every file's content through disk instead of shell variables: `jq --rawfile content "$f"` reads a file's raw bytes directly (only the filename crosses argv), `--slurpfile` assembles the final payload the same way, and `curl --data-binary @file` posts it without ever building a giant `-d` string. Verified locally against this repo's actual `CLAUDE.md`/`README.md`/`UPDATES.md` before pushing — reproduces the exact 164KB payload that broke the old script, now succeeds. This commit's own changes to `CLAUDE.md`/`README.md`/`UPDATES.md` double as the backfill: they re-trigger ingestion through the fixed pipeline so the Velero writeup above (missed by the failed run) actually lands in the chatbot's index.

---

## 2026-07-03

### dove-house-tt deployed — third DNS zone (dovehousett.org), members app + dedicated CNPG

New app: Dove House Table Tennis Club members app (`github.com/akann/dove-house-tt`, private repo — Next.js 16 + better-auth + Drizzle/Postgres). Deployment follows the akan pattern (manifests in the app repo's `k8s/dove-house-tt/`, ghcr.io images, CI sed-patches the image tag) plus the ml/k8s-docs database pattern (dedicated CNPG cluster `dove-house-tt-pg`, pre-created basic-auth credentials secret, barman → MinIO `s3://cnpg-backups/dove-house-tt-pg`, daily ScheduledBackup).

Third DNS zone added, mirroring the nkweini.org precedent end-to-end: new solver in `letsencrypt-prod` (`dnsZones: [dovehousett.org]` → `cloudflare-api-token-dovehousett`), new ExternalSecret from Infisical `/cert-manager/api-token-dovehousett`, new `wildcard-dovehousett` Certificate in ingress-nginx with Reflector annotations → `wildcard-dovehousett-tls` reflected everywhere. App ingress serves apex + www (`from-to-www-redirect`).

Two images per CI run: `ghcr.io/akann/dove-house-tt` (Next standalone runner) and `ghcr.io/akann/dove-house-tt-migrate` (full node_modules, runs `drizzle-kit migrate` as the deployment's initContainer — the pruned standalone output can't run drizzle migrations; Turbopack bundles drizzle-orm/pg into server chunks so they aren't resolvable as packages at runtime). Repo + packages are **private** (switched from public during rollout): needs `repo-dove-house-tt` in argocd ns + `ghcr-secret` dockerconfigjson in the app ns (akan pattern); still no self-hosted runner (ghcr.io is publicly reachable).

**⚠️ Incident found during rollout:** the pre-created proxied A record `dovehousett.org → 62.3.101.140` was serving the **pfSense web GUI login page to the internet** — no NAT forward existed for that WAN IP, so 443 fell through to the firewall GUI listener. Resolved by repointing the A record to 62.3.101.138 (yanatech's WAN IP, which already forwards to ingress-nginx).

**Four rollout snags, all "new namespace" checklist items (in hit order):**
1. Forgot to register the Application in the root `kustomization.yaml` (the file even says to) — nothing deployed until added.
2. NetworkPolicies (wave 3) sync-errored with `namespaces "dove-house-tt" not found` until the wave-9 app created the namespace — self-healed, expected ordering noise.
3. Missing `allow-kube-apiserver-egress` for the new namespace (`netpol-apiserver-egress.yaml`) — CNPG initdb hung on "waiting for the API server to be reachable" (apiserver is 6443 behind the 443 ClusterIP; the app's allow-egress only opens 443).
4. Missing per-namespace egress entry in `netpol-cnpg.yaml`'s `allow-cnpg-operator` (cnpg-system → new namespace, ports 8000/5432/9187) — cluster stuck at 1/2 instances with "Instance Status Extraction Error: HTTP communication issue".

**Kong webhook regression (separate, cluster-wide):** cert-manager couldn't write `wildcard-dovehousett-tls` ("context deadline exceeded" on the secret PATCH) — the two `secrets.*.validation` webhooks in `kong-controller-kong-validations` were back at `timeoutSeconds: 10` (a chart re-render reverted the documented fix; the argocd ignoreDifferences pins the field but doesn't restore the value). Re-patched to 5, cert issued immediately. If a future cert hangs at "Issuing", check this first.

### Ingress access-log dashboard in Grafana (Loki) + two enabling fixes

**Goal:** see HTTP access logs per host (initially `akan.nkweini.org`) in Grafana. New "Ingress Access Logs" dashboard (`uid: ingress-access-logs`, `infrastructure/monitoring/dashboards/cm-ingress-access-logs.yaml`) — `$host` template variable covering all public hosts (defaults to akan), panels for request rate by status class, latency percentiles, top visitor IPs/paths/user agents, and a live log tail. Data source is the existing Loki (`uid: loki`); no new infrastructure.

**Follow-up (same day):** added a `country` field to the JSON log format from Cloudflare's `CF-IPCountry` header (free IP Geolocation, confirmed enabled on the zone — verified end-to-end by curling through a Cloudflare edge IP with `--resolve`: logs showed the real public IP + `country: GB`). Empty for LAN visitors, who bypass Cloudflare via split-horizon DNS. Dashboard gained a filterable "Visitor IPs" table (IP / country / request count) and a "Requests by Country" bar gauge; the log tail line format now shows `[<country>]` after the IP. Transient artifact: `sum by (remote_addr, country)` shows duplicate rows per IP while pre-country log lines are still inside the query window (label set differs) — ages out on its own.

Two pre-existing gaps had to be fixed to make the logs parseable:

1. **ingress-nginx access logs were the default combined format, which has no `$host`** — traffic was only attributable via the upstream name (`[akan-akan-3000]`), and every dashboard panel would have needed brittle regex parsing. Switched to a JSON `log-format-upstream` (with `log-format-escape-json: "true"` so quotes in user agents can't produce invalid JSON) including `host`, `remote_addr`, `status`, `uri`, `request_time`, `user_agent`, etc. Applies to all hosts behind ingress-nginx; nothing else parses these logs, so the format change is safe.
2. **Promtail was shipping raw CRI-prefixed lines** (`<ts> stdout F <log>`) — our custom `config.snippets.scrapeConfigs` override silently discards the chart's default `pipeline_stages`, and the `snippets.pipelineStages: [cri: {}]` value we had set is *only referenced by the default scrapeConfigs template*, so it did nothing. Inlined `pipeline_stages: [- cri: {}]` into the scrape config (and removed the dead `pipelineStages` key). This fixes `| json` / `| logfmt` parsing for **all** namespaces' logs in Loki, not just ingress — and log timestamps now come from the CRI timestamp instead of ingestion time.

**Caveat:** log lines stored *before* these changes keep the CRI prefix + old format, so the dashboard shows nothing for time ranges before the rollout (the `| __error__=""` filter drops unparseable lines by design).

**Follow-up fix — Loki datasource UID pinned:** the Tempo datasource's `lokiSearch/tracesToLogsV2.datasourceUid: loki` in `argocd-app-monitoring.yaml` referenced a UID that didn't exist — no explicit `uid` was set at provisioning, so Grafana generated a hashed one (`P8E80F9AEF21F6940`), and trace→logs links in Tempo had never worked. Fixed by pinning `uid: loki` on the Loki datasource (matching the existing `prometheus`/`alertmanager` convention) rather than chasing the hashed UID; the new dashboard uses `uid: loki` too. Verified nothing else (git or Grafana-DB dashboards) referenced the hashed UID before the change.

**Doc fix that fell out of this:** CLAUDE.md's "infrastructure/monitoring/ bootstrap caveat" was stale — a manual `kubectl apply` of the updated `argocd-app-monitoring.yaml` was silently reverted minutes later (managedFields showed `argocd-controller` re-applying it; the Application's `generation` is in the tens of thousands). The root `kustomization.yaml` + `bootstrap` Application (with `selfHeal: true`) has been continuously syncing all `argocd-app-*.yaml` files from GitHub since it was introduced, monitoring's included. So Application spec changes deploy on push, and unpushed manual applies get reverted. The caveat still holds for the non-Application extras in that directory (`eso-*.yaml`, `external-secret*.yaml`) — those aren't in the root kustomization and do need manual apply. CLAUDE.md rewritten accordingly.

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

**Symptom:** The `ingest-docs.yml` workflow (in this repo, triggered on any `.md` change) failed with `curl` exit code 6 ("Could not resolve host") when POSTing to `https://ml.yanatech.co.uk/k8s-docs/ingest/webhook` — but the exact same URL worked fine from every other place it was tested (an on-prem-cloud-connected machine, `kc1` directly, the `akan` pod). Every other `*.yanatech.co.uk` subdomain (`stocks`, `photos`, etc.) already has an explicit Cloudflare `CNAME` record → `yanatech.co.uk`, `proxied: true` — DNS here is **not wildcarded**, each public subdomain needs its own record added manually. `ml.yanatech.co.uk` simply never got one when the app was set up; every manual test up to that point happened to run from a network/host that could already resolve the internal ingress-nginx path some other way, masking the gap. GitHub Actions' hosted runner, with no such shortcut, was the first thing to actually exercise the real public path — and immediately failed.

**Fix:** Added the missing record via the Cloudflare API (same token cert-manager already uses, `/cert-manager/api-token`), identical shape to the working `stocks.yanatech.co.uk` record:
```bash
curl -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CF_TOKEN" \
  --data '{"type":"CNAME","name":"ml.yanatech.co.uk","content":"yanatech.co.uk","ttl":1,"proxied":true}'
```
Confirmed via `dig @8.8.8.8`/`dig @1.1.1.1` before and after — genuinely nothing publicly resolvable beforehand, resolving correctly (matching the other subdomains' Cloudflare proxy IPs) afterward. Re-ran the failed workflow, then did a one-off full re-ingest of all `.md` files to make sure nothing from the intervening commits (a `git diff HEAD^ HEAD` on a multi-commit push only diffs the last commit — see the shared-services entry below on this exact class of gap) was silently missed.

**Lesson for any new public-facing subdomain on `yanatech.co.uk`:** the Kubernetes-side Ingress/TLS being correctly configured says nothing about whether the DNS record actually exists — that's a separate, manual Cloudflare step, easy to forget because everything still "works" from inside the on-prem cloud network regardless.

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

1. **Harbor unreachable from GitHub-hosted runners.** `harbor.yanatech.co.uk` doesn't resolve outside the on-prem cloud network — CI's `docker` job failed with a DNS lookup error on `ubuntu-latest`. Fix: added `infrastructure/actions-runner/argocd-app-runners-shared-services.yaml`, a dedicated per-repo ARC runner scale set (same pattern as `runners-yana-stocks`), and pointed only the `docker` job at it.
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

---

### Ceph clock skew (pve1-3 NTP) and uptime-kuma `Sync: Unknown` (both resolved, 2026-07-17)

**Ceph clock skew:**

**Symptom:** `ceph -s` reported `HEALTH_WARN clock skew detected on mon.pve2, mon.pve3`.

**Root cause:** All three Proxmox nodes' chrony was still pointed at the Debian default `pool 2.debian.pool.ntp.org` (public internet). That path had been unreachable since the 2026-07-14 PMX_VLAN firewall hardening — the hardening pass already allowed NTP to pfSense's own interface address by design, but the hosts' `chrony.conf` was never repointed from the public pool, so it silently broke the same day and only surfaced 3 days later as accumulated root dispersion tripped Ceph's skew threshold. Confirmed with a raw NTP UDP packet round-trip (a `nc -zu` "open" result is a false positive for actual sync — it doesn't confirm a two-way reply).

**Fix:** confirmed pfSense's PMX_VLAN gateway (`192.168.22.1`) actually answers NTP queries, then added `/etc/chrony/conf.d/pfsense-gateway.conf` (`server 192.168.22.1 iburst prefer`) on pve1/pve2/pve3 and `systemctl restart chrony`. All three synced within seconds; Ceph's `HEALTH_WARN` self-cleared ~30s later via its own periodic timecheck.

**uptime-kuma `Sync: Unknown`:**

**Symptom:** `uptime-kuma`'s ArgoCD Application showed `Sync: Unknown` (not `OutOfSync`) with a `ComparisonError` condition: `spec.strategy.rollingUpdate: Forbidden: may not be specified when strategy type is 'Recreate'`.

**Root cause:** Same class of issue as the Harbor deadlock above — git's `apps/uptime-kuma/deployment.yaml` already specified `strategy.type: Recreate` (the correct fix for a single-replica app on an RWO Ceph RBD PVC), but the **live** Deployment still had a stale `rollingUpdate: {maxSurge: 25%, maxUnavailable: 25%}` block from before that git change, left over from whenever it was last actually applied under `RollingUpdate`. ArgoCD's server-side dry-run diff can't resolve that combination at all, so it reports `Unknown` rather than `OutOfSync` — it's not just behind, it can't be evaluated.

**Fix:** `kubectl patch deployment uptime-kuma -n uptime-kuma --type=merge -p '{"spec":{"strategy":{"rollingUpdate":null,"type":"Recreate"}}}'` — didn't restart the running pod (same pod, same age, 0 restarts after the patch). A forced `argocd.argoproj.io/refresh: hard` confirmed `Synced`/`Healthy` with the `ComparisonError` condition gone.

**Key lesson:** if any other single-replica RWO-PVC app ever shows `Sync: Unknown` with a strategy-related `ComparisonError`, check for exactly this git/live strategy-type drift first — see `CLAUDE.md`'s ArgoCD pitfalls list.
