# Storage & Backup Architecture

The homelab runs three distinct storage layers — block storage for pods, managed Postgres for app data, and object storage as the common backup target — plus two independent backup systems covering different failure modes.

## Ceph RBD: the default StorageClass

Every PVC that doesn't specify otherwise lands on Ceph RBD, backed by a Ceph cluster spanning the 3 Proxmox hosts: 8.4TiB raw across 6 OSDs, monitors reachable at `192.168.22.11-13:6789`. Because the Ceph monitors live on the Proxmox management VLAN while Kubernetes workloads live on a separate VLAN, CSI traffic to the OSD data ports (6802-6809) has to cross that boundary — see the networking doc for why that specific path needs a `CiliumNetworkPolicy` with an explicit CIDR block rather than a standard `NetworkPolicy`.

## CloudNativePG: shared vs. dedicated clusters

Postgres runs entirely on CloudNativePG (CNPG), the Kubernetes-native Postgres operator, but not as one monolithic database. Two patterns are used depending on the app:

- **Shared cluster (`pg-main`)** — a single 4-instance CNPG cluster hosts several lower-traffic apps that don't need isolation from each other: Vaultwarden, Authentik, Nextcloud, Infisical, Apicurio.
- **Dedicated clusters** — apps with heavier or more specialized database needs get their own CNPG cluster: `auth-service-pg` for yana-stocks' auth service, `immich-postgres` (running a pgvector-enabled Postgres image for similarity search), `k8s-docs-pg` (same pgvector image, backing the RAG chatbot's embeddings), `dove-house-tt-pg`.

Every CNPG cluster streams WAL continuously to MinIO via barman, which gives point-in-time recovery to any second, not just to the last scheduled backup. Most clusters also run a daily `ScheduledBackup` on top of continuous WAL streaming.

One operational constraint worth calling out: CNPG clusters need at least 2 instances for the cluster's node-reboot automation (see below) to actually drain a node cleanly. A single-instance cluster sets its own PodDisruptionBudget to zero allowed disruptions, which permanently blocks the drain the reboot daemon is trying to perform — the node gets stuck cordoned with no obvious cause unless you know to check CNPG's PDB status specifically.

## Node reboots: kured

Unattended node patching is handled by `kured`, which watches for a reboot-required marker on each node and drains it before rebooting. Two settings tune how aggressive it is: a 5-minute drain timeout (rather than waiting indefinitely for a stubborn pod to evict), and `forceReboot: true`, which reboots the node even if the drain didn't fully complete — relying on CNPG's WAL replay to bring a Postgres primary back to consistency after an unclean stop, rather than blocking the whole cluster's patch cycle on one pod.

## Non-CNPG database backups

Not everything runs on CNPG. Harbor's own metadata database is a plain Postgres `StatefulSet`, not a CNPG cluster, so it gets a simpler daily `pg_dump` CronJob writing to MinIO with a rolling 7-day filename scheme (`harbor-Monday.sql.gz` through `harbor-Sunday.sql.gz`) rather than continuous WAL streaming.

## Velero: whole-PVC backup, independent of the database layer

Separately from CNPG's Postgres-specific backups, Velero runs a filesystem-level backup (via its Kopia integration) of every PVC in the cluster on a weekly schedule, shipping to a Backblaze B2 bucket rather than the in-cluster MinIO — a deliberate off-cluster target so a cluster-wide storage failure doesn't also take out the backups. This is the safety net for stateful data that isn't a CNPG database: uploaded files, application state on plain volumes, and so on.

This is also the one piece of the backup story that's honestly not fully healthy right now: the last several weekly runs have come back `PartiallyFailed` with a growing count of per-item warnings, despite the backup storage location itself reporting healthy. The root cause hasn't been isolated yet — the next debugging step is pulling per-item failure detail from Velero's own backup-describe output rather than just the summary status.

## MinIO as the common backup substrate

MinIO, running in-cluster, is the S3-compatible target for everything that doesn't need to leave the cluster: CNPG's barman WAL archives, Harbor's `pg_dump` output, and yana-stocks' Turborepo remote build cache all land in different buckets on the same MinIO instance. It's deliberately not used for Velero's PVC backups, since those need to survive a failure of the cluster (and therefore MinIO) itself.
