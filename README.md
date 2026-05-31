# Homelab Infrastructure Documentation

## Overview

3-node Proxmox cluster running a 6-node Kubernetes cluster with Ceph storage, GitOps deployments via ArgoCD, and multiple self-hosted services. All infrastructure and apps are managed via ArgoCD pointing at `github.com/akann/k8s-apps`.

---

## Hardware

| Host | IP | Hardware |
|---|---|---|
| pve1 | 192.168.22.11 | MINISFORUM MS-01, Intel i5-12600H, 64GB RAM |
| pve2 | 192.168.22.12 | MINISFORUM MS-01, Intel i5-12600H, 64GB RAM |
| pve3 | 192.168.22.13 | MINISFORUM MS-01, Intel i5-12600H, 64GB RAM |

Each host: 16 vCPUs, 64GB RAM, 8GB Swap

### Storage per host

| Device | Model | Size |
|---|---|---|
| nvme0n1 | Lexar NM790 | 2TB |
| nvme1n1 | Lexar NM790 | 1TB |
| nvme2n1 | CT500P3PSSD8 (Crucial) | 500GB |

---

## Proxmox Configuration

- **Version:** 9.2.2
- **Cluster name:** cluster01
- **Corosync transport:** knet with secure auth

### Network Interfaces

| Interface | pve1 | pve2 | pve3 | Purpose |
|---|---|---|---|---|
| vmbr0 | 192.168.22.11/24 | 192.168.22.12/24 | 192.168.22.13/24 | Management + VM traffic |
| vmbr1 | 192.168.33.11/24 | 192.168.33.12/24 | 192.168.33.13/24 | Secondary bridge |
| enp2s0f0np0 | 10.10.10.1/30 | 10.10.10.2/30 | 10.10.20.2/30 | FRR/OSPF link |
| enp2s0f1np1 | 10.10.20.1/30 | 10.10.30.1/30 | 10.10.30.2/30 | FRR/OSPF link |
| lo:ospf | 10.255.255.1/32 | 10.255.255.2/32 | 10.255.255.3/32 | OSPF loopback |

- vmbr0: VLAN-aware, bridge-vids 22 111
- vmbr1: VLAN-aware, bridge-vids 33 44 55 66
- FRR interfaces: MTU 9000

---

## Ceph Storage

- **Cluster FSID:** `92197a62-7cf9-49eb-a0cb-5e0b9bbff52a`
- **Health:** HEALTH_OK
- **Total capacity:** 8.4 TiB

### OSDs

| OSD | Host | Size |
|---|---|---|
| osd.0 | pve1 | 2TB (Lexar NM790) |
| osd.3 | pve1 | 1TB (Lexar NM790) |
| osd.1 | pve2 | 2TB (Lexar NM790) |
| osd.4 | pve2 | 1TB (Lexar NM790) |
| osd.2 | pve3 | 2TB (Lexar NM790) |
| osd.5 | pve3 | 1TB (Lexar NM790) |

### Pools

| Pool | Type | Size | Application |
|---|---|---|---|
| .mgr | replicated | 3 | mgr |
| cephfs_metadata | replicated | 3 | cephfs |
| cephfs_data | replicated | 3 | cephfs |
| rbd | replicated | 3 | rbd (Proxmox VMs) |
| kubernetes | replicated | 3 | rbd (Kubernetes PVs) |

### Storage Config Notes
- `rbd` storage: `krbd 0` (librbd/QEMU native — required for cross-node VM cloning)
- Ceph client for Kubernetes: `client.kubernetes`
- Kubernetes client key: stored in K8s secret `csi-rbd-secret` in `ceph-csi-rbd` namespace
- Client key also stored in Vaultwarden

### Monitors
```
192.168.22.11:6789 (pve1)
192.168.22.12:6789 (pve2)
192.168.22.13:6789 (pve3)
```

---

## Proxmox Templates

| VMID | Name | Notes |
|---|---|---|
| 9000 | ubuntu-2404-template | Main template — disks on rbd, cloudinit on rbd |
| 901 | ubuntu-24-template | Older template |

### Template Configuration (9000)
- OS: Ubuntu 24.04
- BIOS: OVMF (UEFI)
- Machine: q35
- CPU: host (required for x86-64-v2 support)
- Storage: rbd pool
- Cloud-init: `user=local:snippets/k8s-init.yaml`

### Cloud-init Snippet (`/var/lib/vz/snippets/k8s-init.yaml`)
```yaml
#cloud-config
package_update: true
package_upgrade: true
packages:
  - qemu-guest-agent
  - open-iscsi
  - nfs-common
  - curl
  - apt-transport-https
users:
  - name: ubuntu
    lock_passwd: false
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - <pve1 root ssh key>
chpasswd:
  expire: false
  users:
    - {name: ubuntu, password: ubuntu, type: text}
ssh_pwauth: true
preserve_hostname: false
runcmd:
  - systemctl enable --now qemu-guest-agent
  - swapoff -a
  - sed -i '/\bswap\b/d' /etc/fstab
  - modprobe overlay
  - modprobe br_netfilter
  - echo -e "overlay\nbr_netfilter" > /etc/modules-load.d/k8s.conf
  - echo -e "net.bridge.bridge-nf-call-iptables=1\nnet.ipv4.ip_forward=1\nnet.bridge.bridge-nf-call-ip6tables=1" > /etc/sysctl.d/k8s.conf
  - sysctl --system
```

**Important:** Snippet must be copied to all nodes:
```bash
scp /var/lib/vz/snippets/k8s-init.yaml pve2:/var/lib/vz/snippets/
scp /var/lib/vz/snippets/k8s-init.yaml pve3:/var/lib/vz/snippets/
```

---

## Kubernetes VMs

| VMID | Name | Role | Host | IP | vCPU | RAM | Disk |
|---|---|---|---|---|---|---|---|
| 101 | k8s-cp-1 | control-plane | pve1 | 192.168.22.21 | 4 | 8GB | 50GB |
| 102 | k8s-cp-2 | control-plane | pve2 | 192.168.22.22 | 4 | 8GB | 50GB |
| 103 | k8s-cp-3 | control-plane | pve3 | 192.168.22.23 | 4 | 8GB | 50GB |
| 201 | k8s-worker-1 | worker | pve1 | 192.168.22.31 | 8 | 40GB | 100GB |
| 202 | k8s-worker-2 | worker | pve2 | 192.168.22.32 | 8 | 40GB | 100GB |
| 203 | k8s-worker-3 | worker | pve3 | 192.168.22.33 | 8 | 40GB | 100GB |

### VM Notes
- CPU type: `host` (required — x86-64-v2 needed for ceph-csi containers)
- Network: `vmbr0`, no VLAN tag (removed to allow LAN communication)
- OS user: `ubuntu` / `ubuntu`
- SSH: pve1 root key authorized

### VM Management Commands
```bash
# Start/stop from correct host
qm start 101 && qm start 201                          # pve1
ssh pve2 "qm start 102 && qm start 202"               # pve2
ssh pve3 "qm start 103 && qm start 203"               # pve3

# Set config on remote VMs (must ssh to host)
ssh pve2 "qm set 102 --cores 4 ..."
ssh pve3 "qm set 103 --cores 4 ..."

# View all cluster VMs
pvesh get /cluster/resources --type vm
```

---

## Kubernetes Cluster

- **Version:** v1.32.13
- **Control plane endpoint:** `192.168.22.21:6443`
- **Pod network CIDR:** `10.244.0.0/16`

### Components

| Component | Version/Details |
|---|---|
| Container runtime | containerd |
| CNI | Flannel |
| Ceph CSI | ceph-csi-rbd (namespace: ceph-csi-rbd) |
| Default StorageClass | ceph-rbd |
| Load balancer | MetalLB |
| Ingress | ingress-nginx (2 replicas) |
| TLS | cert-manager + Let's Encrypt (DNS-01 via Cloudflare) |
| Monitoring | kube-prometheus-stack |
| SSO | Authentik |
| GitOps | ArgoCD v3.4.2 |
| Message broker | Apache Kafka 4.2.0 (Strimzi 1.0.0, KRaft mode) |
| Password manager | Vaultwarden |
| Backups | Velero → Backblaze B2 |
| Secret replication | Reflector |

### kubectl Access
```bash
ssh ubuntu@192.168.22.21
kubectl get nodes
```

---

## Networking

### MetalLB
- **IP Pool:** `192.168.22.200 - 192.168.22.220` (pool name: `k8s-pool`)
- **Mode:** L2Advertisement
- **Ingress VIP:** `192.168.22.200` (ingress-nginx)

### pfSense NAT
- `62.3.101.138:80` → `192.168.22.200:80`
- `62.3.101.138:443` → `192.168.22.200:443`
- `62.3.101.138` dedicated to Kubernetes traffic

### DNS (Cloudflare)
- `yanatech.co.uk` → `62.3.101.138`
- `*.yanatech.co.uk` → `62.3.101.138` (via CNAME to yanatech.co.uk)

---

## TLS / cert-manager

- **cert-manager version:** v1.20.2 (jetstack Helm chart, ArgoCD-managed — `infrastructure/cert-manager/argocd-app-cert-manager.yaml`, pinned `targetRevision: v1.20.2`)
- **Issuer:** `letsencrypt-prod` (ClusterIssuer)
- **Challenge:** DNS-01 via Cloudflare
- **Cloudflare API token secret:** `cloudflare-api-token` in `cert-manager` namespace (stored in Vaultwarden)
- **Wildcard cert:** `wildcard-yanatech-tls` in `ingress-nginx` namespace
- **Covers:** `yanatech.co.uk` and `*.yanatech.co.uk`
- **Renewal:** automatic by cert-manager, every ~90 days

### Reflector
- Installed in `kube-system`
- Auto-replicates `wildcard-yanatech-tls` to all namespaces
- Annotation on secret: `reflector.v1.k8s.emberstack.com/reflection-auto-enabled="true"`

---

## Kafka

- **Operator:** Strimzi 1.0.0
- **Kafka version:** 4.2.0
- **Mode:** KRaft (no ZooKeeper)
- **Brokers:** 3 (dual-role: controller + broker)
- **Storage:** 20Gi ceph-rbd per broker
- **Namespace:** `kafka`

### Internal bootstrap endpoints
```
kafka-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092  # plaintext
kafka-cluster-kafka-bootstrap.kafka.svc.cluster.local:9093  # TLS
```

### UI
- Kafka UI (Provectus): https://kafka.yanatech.co.uk

---

## PostgreSQL (Shared Database VM)

Dedicated Proxmox VM for app databases that must survive a Kubernetes cluster rebuild (Vaultwarden, Authentik) plus any future apps needing Postgres (e.g. Nextcloud). Lives outside k8s on purpose — a cluster teardown can't take the credential/identity data with it.

### VM

| VMID | Name | Host | IP | vCPU | RAM | Disk |
|---|---|---|---|---|---|---|
| 110 | postgres-1 | pve1 (HA-managed, can run on any node) | 192.168.22.40 | 2 | 4GB | 20GB on `rbd` |

- Cloned full from template 9000; CPU type `host`; `vmbr0`, no VLAN tag
- Cloud-init: `--cicustom "user=local:snippets/postgres-init.yaml"`
- Disk is thin-provisioned on Ceph and grows online: `qm resize 110 scsi0 +Ng` → `growpart /dev/sda 1` → `resize2fs /dev/sda1`
- HA enabled: `ha-manager add vm:110 --state started --max_restart 3`

### Cloud-init Snippet (`/var/lib/vz/snippets/postgres-init.yaml`)
Must be copied to all three nodes (node-local storage). Installs PostgreSQL 18 from the PGDG repo.
```yaml
#cloud-config
package_update: true
package_upgrade: true
packages:
  - qemu-guest-agent
  - curl
  - ca-certificates
  - gnupg
users:
  - name: ubuntu
    lock_passwd: false
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - <pve1 root ssh key>
chpasswd:
  expire: false
  users:
    - {name: ubuntu, password: ubuntu, type: text}
ssh_pwauth: true
preserve_hostname: false
runcmd:
  - systemctl enable --now qemu-guest-agent
  - install -d /usr/share/postgresql-common/pgdg
  - curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc
  - sh -c 'echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt noble-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
  - apt-get update
  - apt-get install -y postgresql-18
```

### PostgreSQL Config

- **Version:** 18.4 (PGDG repo, `noble-pgdg`)
- Config dir: `/etc/postgresql/18/main/`
- Tuning drop-in `conf.d/tuning.conf`: `listen_addresses = '*'`, `shared_buffers 1GB`, `effective_cache_size 3GB`, `maintenance_work_mem 256MB`, `work_mem 16MB`, `max_connections 200`, `wal_compression on`
- LAN access via `pg_hba.conf`: `host all all 192.168.22.0/24 scram-sha-256`

### Databases / Roles

| Database | Owner role | Used by |
|---|---|---|
| vaultwarden | vaultwarden | Vaultwarden ✅ live (migrated from Authentik's PG 2026-05-31) |
| authentik | authentik | Authentik (migration pending) |

- Role passwords (scram-sha-256) stored in Vaultwarden
- **`vaultwarden` role password must ALSO live outside Vaultwarden** (bootstrap secret manifest) — otherwise a cold rebuild is a circular-dependency lockout
- Bump RAM to 8GB + `shared_buffers` to 2GB once Authentik (and more) land here

### Backups

- **Not covered by Velero** (that's k8s-namespace only). DB-level dumps are the safety net against logical corruption.
- `/usr/local/bin/pg-backup.sh`: nightly `pg_dumpall | gzip` → Backblaze B2 (`b2:yanatech-pg/`) via rclone, 7-day local retention in `/var/backups/pg`
- Cron: `/etc/cron.d/pg-backup`, daily 02:30

---

## Velero Backups

- **Backend:** Backblaze B2
- **Bucket:** `yanatech-velero`
- **Endpoint:** `s3.eu-central-003.backblazeb2.com`
- **Schedule:** Daily at 2am UTC
- **Retention:** 30 days
- **Namespaces backed up:** vaultwarden, authentik, monitoring, kafka, ingress-nginx, cert-manager, argocd
- **Credentials secret:** `velero-b2-credentials` in `velero` namespace (stored in Vaultwarden)

### Manual backup
```bash
velero backup create manual-backup --include-namespaces vaultwarden,authentik
```

### Restore
```bash
velero backup get
velero restore create --from-backup <backup-name>
```

---

## Installed Services

| Service | Namespace | URL | Managed by |
|---|---|---|---|
| ingress-nginx | ingress-nginx | - | ArgoCD |
| MetalLB | metallb-system | - | ArgoCD |
| cert-manager | cert-manager | - | ArgoCD |
| Reflector | kube-system | - | ArgoCD |
| Ceph CSI RBD | ceph-csi-rbd | - | ArgoCD |
| Prometheus+Grafana | monitoring | https://grafana.yanatech.co.uk | ArgoCD |
| ArgoCD | argocd | https://argocd.yanatech.co.uk | Helm |
| Authentik | authentik | https://auth.yanatech.co.uk | ArgoCD |
| Vaultwarden | vaultwarden | https://vault.yanatech.co.uk | ArgoCD |
| Kafka | kafka | - | ArgoCD |
| Kafka UI | kafka | https://kafka.yanatech.co.uk | ArgoCD |
| Velero | velero | - | ArgoCD |
| Uptime Kuma | uptime-kuma | https://status.yanatech.co.uk | ArgoCD |
| Headlamp | headlamp | https://headlamp.yanatech.co.uk | ArgoCD |
| yanatech website | yanatech | https://www.yanatech.co.uk | ArgoCD |

---

## Git Repositories

| Repo | Purpose |
|---|---|
| github.com/akann/yanatech | Next.js website + k8s/ manifests |
| github.com/akann/k8s-apps | All infrastructure and app manifests (GitOps) |

### k8s-apps Structure
```
k8s-apps/
├── bootstrap.sh             # Run on fresh cluster after ArgoCD install
├── argocd/                  # (legacy — not used, see bootstrap.sh)
├── apps/
│   ├── uptime-kuma/         ✅ deployed
│   ├── vaultwarden/         ✅ deployed
│   ├── kafka/               ✅ deployed
│   ├── kafka-ui/            ✅ deployed
│   └── nextcloud/           📋 pending
└── infrastructure/
    ├── metallb/             ✅ deployed
    ├── cert-manager/        ✅ deployed
    ├── ingress-nginx/       ✅ deployed
    ├── monitoring/          ✅ deployed
    ├── authentik/           ✅ deployed
    ├── reflector/           ✅ deployed
    ├── ceph-csi/            ✅ deployed
    ├── headlamp/            ✅ deployed
    └── velero/              ✅ deployed
```

### Fresh Cluster Bootstrap
```bash
# 1. Install ArgoCD
# 2. Create manual secrets (all stored in Vaultwarden):
#    - csi-rbd-secret in ceph-csi-rbd
#    - cloudflare-api-token in cert-manager
#    - grafana-authentik-secret in monitoring
#    - authentik-secret in authentik
#    - vaultwarden-secret in vaultwarden
#    - velero-b2-credentials in velero
# 3. Run bootstrap script:
bash bootstrap.sh
```

### Manual Secrets Reference
| Secret | Namespace | Contents |
|---|---|---|
| `csi-rbd-secret` | ceph-csi-rbd | Ceph client.kubernetes key |
| `cloudflare-api-token` | cert-manager | Cloudflare API token |
| `grafana-authentik-secret` | monitoring | Authentik OAuth client_id + client_secret |
| `authentik-secret` | authentik | DB creds, Redis host, secret key |
| `vaultwarden-secret` | vaultwarden | DATABASE_URL (→ VM 110, `192.168.22.40`), ADMIN_TOKEN, DOMAIN |
| `velero-b2-credentials` | velero | Backblaze B2 keyID + applicationKey |

### yanatech CI/CD Pipeline
```
git push → GitHub Actions builds image →
pushes to ghcr.io/akann/yanatech:<sha> →
updates k8s/deployment.yaml image tag →
ArgoCD detects change → deploys to cluster
```

- Image registry: `ghcr.io/akann/yanatech` (private)
- Pull secret: `ghcr-secret` in `yanatech` namespace
- Health endpoint: `GET /api/health` → `{"status":"ok"}`

---

## Pending / TODO

- [x] Dedicated PostgreSQL VM on Proxmox for shared database (VM 110 — see PostgreSQL section)
- [ ] Authentik SSO integration: Grafana, ArgoCD, Headlamp
- [ ] Nextcloud (self-hosted cloud storage)
- [x] Move Vaultwarden database to dedicated PostgreSQL VM (done 2026-05-31 — now on VM 110; old DB retained on Authentik's PG as rollback)
- [ ] Move Authentik database to VM 110 (decouples Vaultwarden from Authentik's bundled Postgres)

---

## Known Issues / Notes

- `qm list` only shows local node VMs — use `pvesh get /cluster/resources --type vm` for all
- `qm set` / `qm start` for VMs on remote nodes must be run via `ssh pve2/pve3`
- CPU type must be `host` on all K8s VMs (x86-64-v2 requirement for ceph-csi)
- ArgoCD ingress backend must use HTTP (insecure mode enabled on argocd-server)
- Wildcard TLS secret must exist in each namespace — Reflector handles this automatically
- pfSense web UI must not use port 443 on `62.3.101.138` (conflicts with K8s ingress)
- Authentik requires PostgreSQL and Redis — both enabled via Helm values
- ArgoCD v3.4 does not support app-of-apps via directory source for Application resources — use bootstrap.sh instead
- MetalLB IP pool name is `k8s-pool` (not `default-pool`)
- Vaultwarden database now lives on VM 110 (`192.168.22.40`, db `vaultwarden`), migrated off Authentik's bundled Postgres 2026-05-31. `DATABASE_URL` in `vaultwarden-secret` points there; role password is URL-safe hex (a base64 password breaks `postgresql://` parsing). Old DB left on Authentik's PG as rollback — drop once confident
- Vaultwarden Deployment must use `strategy: { type: Recreate }`. Its `/data` PVC is RWO on ceph-rbd, so the default RollingUpdate deadlocks on restart — the new pod can't mount the volume while the old pod holds it (Multi-Attach), leaving the rollout stuck. If it ever deadlocks, `scale --replicas=0` (wait for both pods gone) then `--replicas=1`
- Migrating a Postgres DB between the in-cluster Bitnami instance and VM 110: the Bitnami pod stores passwords in files (`$POSTGRES_PASSWORD_FILE`, `$POSTGRES_POSTGRES_PASSWORD_FILE`), not env values, and the `postgres` superuser password in the file can be stale vs the running DB — the `authentik` role (cluster owner) works. Dump/load via `PGPASSWORD` + discrete `PG*` env vars, never a `postgresql://` URL, to avoid special-char parsing failures
- Strimzi 1.0.0 only supports Kafka 4.x — do not use 3.x versions
- kube-prometheus-stack Helm release name is `kube-prometheus-stack` (set via releaseName in ArgoCD app)
- `bootstrap.sh` enumerates every ArgoCD Application explicitly (no globbing) — a new app needs BOTH its `argocd-app-<name>.yaml` committed AND a matching `kubectl apply` line in `bootstrap.sh`, or it won't deploy on a fresh cluster (this gap previously hit authentik, velero, uptime-kuma)
- ArgoCD does NOT honor Helm's `crds.keep` / `helm.sh/resource-policy: keep` annotation when pruning — deleting a CRD-bearing Application (cert-manager, metallb, etc.) can cascade-delete its CRDs and all dependent resources. Don't delete those Applications directly; `crds.keep: true` only protects against `helm uninstall`
- cert-manager operator is ArgoCD-managed via the jetstack chart (was a manual `helm install` until migrated) — the `cert-manager` app must apply before `cert-manager-config` so CRDs exist before the ClusterIssuer; bootstrap.sh orders them correctly, and the config app self-heals if it races ahead
- ArgoCD can show a permanent `OutOfSync` (app still Healthy) when the kube-apiserver defaults a field the Helm chart doesn't template — e.g. `hostUsers: true` on Deployments (v1.32 user-namespace defaulting). It's cosmetic, not real drift; a sync won't fix it because the apiserver re-adds the field. Fix with an `ignoreDifferences` entry on that jsonPointer (see `infrastructure/headlamp/argocd-app-headlamp.yaml` → `/spec/template/spec/hostUsers` for the pattern)
- Cloud-init `users:` list must NOT include `- default` alongside an explicit `- name: ubuntu` — on Ubuntu cloud images the default user is already `ubuntu`, so the two definitions collide and `lock_passwd` / `chpasswd` / `ssh_pwauth` silently fail to apply, locking you out of the VM (no password, sometimes no key). Define `ubuntu` explicitly with no `- default` entry. Applies to every cloud-init snippet (`k8s-init.yaml`, `postgres-init.yaml`, etc.)
- Cloud-init `chpasswd: { list: ... }` is deprecated and silently no-ops on the cloud-init shipped with Ubuntu 24.04 — the password never gets set, so console/password login fails even though SSH-key login still works (this is why the k8s VMs always worked by key but not by password). Use the modern form: `chpasswd: { expire: false, users: [{name: ubuntu, password: ubuntu, type: text}] }`. User/password modules only run once per instance, so an already-booted VM needs a fresh clone to pick up a snippet change
