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
| authentik | authentik | Authentik ✅ live (migrated 2026-05-31; bundled PG kept as rollback) |

- Role passwords (scram-sha-256) stored in Vaultwarden
- **`vaultwarden` role password must ALSO live outside Vaultwarden** (bootstrap secret manifest) — otherwise a cold rebuild is a circular-dependency lockout
- Bump RAM to 8GB + `shared_buffers` to 2GB once Authentik (and more) land here

### Backups

- **Not covered by Velero** (that's k8s-namespace only). DB-level dumps are the safety net against logical corruption.
- `/usr/local/bin/pg-backup.sh`: nightly `pg_dumpall | gzip` → Backblaze B2 (`b2:yanatech-pg/`) via rclone, 7-day local retention in `/var/backups/pg`
- Cron: `/etc/cron.d/pg-backup`, daily 02:30 ✅ live (verified 2026-06-01)
- rclone configured at `/root/.config/rclone/rclone.conf` (runs as root via cron) — B2 key scoped to `yanatech-pg` bucket, stored in Vaultwarden
- Also copy config to ubuntu home if needed: `sudo cp /root/.config/rclone/rclone.conf ~/.config/rclone/rclone.conf`

---

## Proxmox Config Backups

Nightly backup of Proxmox cluster config and node-local files to Backblaze B2 via rclone. Runs on pve1.

- **Script:** `/usr/local/bin/proxmox-backup.sh` on pve1
- **Cron:** `/etc/cron.d/proxmox-backup`, daily 03:30 ✅ live (verified 2026-06-01)
- **Bucket:** `yanatech-proxmox`
- **Retention:** 30 days
- **B2 key:** `pg` key (keyID `003faa10a09691a0000000002`) — stored in Vaultwarden
- **rclone config:** `/root/.config/rclone/rclone.conf` on pve1

### What's backed up
- `/etc/pve/` — cluster config, VM/CT definitions, storage, network (replicated cluster-wide)
- `/etc/network/interfaces` — node network config
- `/var/lib/vz/snippets/` — cloud-init snippets

### Script
```bash
#!/usr/bin/env bash
set -euo pipefail
ts=$(date +%F)
archive="/tmp/proxmox-backup-$ts.tar.gz"
tar czf "$archive" /etc/pve/ /etc/network/interfaces /var/lib/vz/snippets/ 2>/dev/null || true
rclone copy "$archive" b2:yanatech-proxmox/
rm -f "$archive"
rclone delete --min-age 30d b2:yanatech-proxmox/
```

---

## pgAdmin4

Web-based PostgreSQL management UI for pg1. Deployed to Kubernetes via ArgoCD, accessible at `https://pgadmin.yanatech.co.uk`.

- **Namespace:** `pgadmin`
- **Helm chart:** `pgadmin4` from `https://helm.runix.net`, version `1.64.0`
- **Auth:** Authentik SSO (OAuth2) + internal fallback (`admin@yanatech.co.uk` / `pgadmin`)
- **OAuth2 credentials:** `pgadmin-oauth-secret` in `pgadmin` namespace (stored in Vaultwarden)
- **Config:** `config_local.py` mounted via ConfigMap `pgadmin-config-local` in `pgadmin` namespace
- **Connected to:** pg1 (`192.168.22.40`) — `vaultwarden` and `authentik` databases

### Bootstrap prerequisites (manually created, not in git)
```bash
kubectl create namespace pgadmin

kubectl create secret generic pgadmin-oauth-secret \
  --namespace pgadmin \
  --from-literal=OAUTH2_CLIENT_ID=<client-id> \
  --from-literal=OAUTH2_CLIENT_SECRET=<client-secret>

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: pgadmin-config-local
  namespace: pgadmin
data:
  config_local.py: |
    AUTHENTICATION_SOURCES = ['oauth2', 'internal']
    OAUTH2_AUTO_CREATE_USER = True
    OAUTH2_CONFIG = [
      {
        'OAUTH2_NAME': 'Authentik',
        'OAUTH2_DISPLAY_NAME': 'Login with Authentik',
        'OAUTH2_CLIENT_ID': '<client-id>',
        'OAUTH2_CLIENT_SECRET': '<client-secret>',
        'OAUTH2_TOKEN_URL': 'https://auth.yanatech.co.uk/application/o/token/',
        'OAUTH2_AUTHORIZATION_URL': 'https://auth.yanatech.co.uk/application/o/authorize/',
        'OAUTH2_API_BASE_URL': 'https://auth.yanatech.co.uk/application/o/pgadmin/',
        'OAUTH2_SERVER_METADATA_URL': 'https://auth.yanatech.co.uk/application/o/pgadmin/.well-known/openid-configuration',
        'OAUTH2_USERINFO_ENDPOINT': 'https://auth.yanatech.co.uk/application/o/userinfo/',
        'OAUTH2_JWKS_URI': 'https://auth.yanatech.co.uk/application/o/pgadmin/jwks/',
        'OAUTH2_SCOPE': 'openid email profile',
        'OAUTH2_ICON': 'fa-openid',
        'OAUTH2_BUTTON_COLOR': '#fd4b2d',
      }
    ]
EOF
```

### Authentik provider settings
- Slug: `pgadmin`
- Redirect URI: `https://pgadmin.yanatech.co.uk/oauth2/authorize`
- Signing Key: `authentik Self-signed Certificate`
- Scopes: `openid`, `profile`, `email`

---

## Velero Backups

- **Backend:** Backblaze B2
- **Bucket:** `yanatech-velero`
- **Endpoint:** `s3.eu-central-003.backblazeb2.com`
- **Schedule:** Daily at 2am UTC ✅ live (verified 2026-06-01)
- **Retention:** 30 days
- **Namespaces backed up:** vaultwarden, authentik, monitoring, kafka, ingress-nginx, cert-manager, argocd
- **Credentials secret:** `velero-b2-credentials` in `velero` namespace (stored in Vaultwarden)
- **B2 key:** `velero` key scoped to `yanatech-velero` bucket (keyID `003faa10a09691a0000000003`)

### Manual backup
```bash
kubectl create -f - <<'EOF'
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: manual-test-backup
  namespace: velero
spec:
  includedNamespaces:
    - vaultwarden
    - authentik
  ttl: 24h0m0s
EOF
kubectl get backup manual-test-backup -n velero -w
```

### Restore
```bash
kubectl get backups -n velero
velero restore create --from-backup <backup-name>
```

### Troubleshooting
- If `BackupStorageLocation` shows `Unavailable` with `no EC2 IMDS role found` — the `velero-b2-credentials` secret has malformed newlines. Recreate it:
```bash
kubectl delete secret velero-b2-credentials -n velero
kubectl create secret generic velero-b2-credentials \
  --namespace velero \
  --from-literal=cloud="[default]
aws_access_key_id=<keyID>
aws_secret_access_key=<applicationKey>"
kubectl rollout restart deployment/velero -n velero
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
| pgAdmin4 | pgadmin | https://pgadmin.yanatech.co.uk | ArgoCD |
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
│   ├── pgadmin/             ✅ deployed
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
#    - pgadmin-oauth-secret in pgadmin (OAUTH2_CLIENT_ID, OAUTH2_CLIENT_SECRET)
#    - pgadmin-config-local ConfigMap in pgadmin (config_local.py with OAuth2 config)
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
| `pgadmin-oauth-secret` | pgadmin | Authentik OAuth2 OAUTH2_CLIENT_ID + OAUTH2_CLIENT_SECRET |

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
- [x] Authentik SSO integration: Grafana ✅ (done 2026-05-31), ArgoCD ✅ (done 2026-05-31), Headlamp ⏳ (blocked by upstream Headlamp bug — refresh token not issued), pgAdmin4 ✅ (done 2026-06-01)
- [x] pgAdmin4 deployment with Authentik SSO (done 2026-06-01 — `apps/pgadmin/`, connected to pg1 at 192.168.22.40)
- [ ] Nextcloud (self-hosted cloud storage)
- [x] Move Vaultwarden database to dedicated PostgreSQL VM (done 2026-05-31 — now on VM 110; old DB dropped from Authentik's PG, final dump kept on cp-1)
- [x] Move Authentik database to VM 110 (done 2026-05-31 — `authentik-secret.__HOST` → `192.168.22.40`; bundled Bitnami PG still running as rollback)
- [ ] Remove bundled Authentik Postgres: set `postgresql.enabled: false` + delete the `postgresql:` block in the ArgoCD app values (ArgoCD prunes the StatefulSet + PVC; also scrubs the plaintext PG password from git) — do once confident

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
- Vaultwarden database now lives on VM 110 (`192.168.22.40`, db `vaultwarden`), migrated off Authentik's bundled Postgres 2026-05-31. `DATABASE_URL` in `vaultwarden-secret` points there; role password is URL-safe hex (a base64 password breaks `postgresql://` parsing). Old DB dropped from Authentik's PG 2026-05-31 — final pre-drop dump retained on cp-1
- Vaultwarden Deployment must use `strategy: { type: Recreate }`. Its `/data` PVC is RWO on ceph-rbd, so the default RollingUpdate deadlocks on restart — the new pod can't mount the volume while the old pod holds it (Multi-Attach), leaving the rollout stuck. If it ever deadlocks, `scale --replicas=0` (wait for both pods gone) then `--replicas=1`
- Migrating a Postgres DB between the in-cluster Bitnami instance and VM 110: the Bitnami pod stores passwords in files (`$POSTGRES_PASSWORD_FILE`, `$POSTGRES_POSTGRES_PASSWORD_FILE`), not env values, and the `postgres` superuser password in the file can be stale vs the running DB — the `authentik` role (cluster owner) works. Dump/load via `PGPASSWORD` + discrete `PG*` env vars, never a `postgresql://` URL, to avoid special-char parsing failures
- Authentik DB connection lives entirely in the manual `authentik-secret` (`AUTHENTIK_POSTGRESQL__HOST/__NAME/__USER/__PASSWORD`); the chart sets `authentik.existingSecret` and does NOT put the host in values, so cutover = patch `__HOST` in the secret + restart `authentik-server`/`authentik-worker`. No git change needed for the repoint
- Authentik's ArgoCD app has `automated.selfHeal: true` — pause it (`argocd app set authentik --sync-policy none`) before scaling deployments to 0 for a migration, or self-heal scales them straight back. Re-enable with `--sync-policy automated --self-heal --auto-prune` after
- Loading an Authentik dump into a fresh DB needs a SUPERUSER (the dump has `CREATE EXTENSION` + materialized views a plain LOGIN role can't create, and `ON_ERROR_STOP` aborts the whole load on the first one). Temporarily `ALTER ROLE authentik SUPERUSER` on VM 110 for the load, then `NOSUPERUSER`
- Strimzi 1.0.0 only supports Kafka 4.x — do not use 3.x versions
- kube-prometheus-stack Helm release name is `kube-prometheus-stack` (set via releaseName in ArgoCD app)
- `bootstrap.sh` enumerates every ArgoCD Application explicitly (no globbing) — a new app needs BOTH its `argocd-app-<name>.yaml` committed AND a matching `kubectl apply` line in `bootstrap.sh`, or it won't deploy on a fresh cluster (this gap previously hit authentik, velero, uptime-kuma)
- ArgoCD does NOT honor Helm's `crds.keep` / `helm.sh/resource-policy: keep` annotation when pruning — deleting a CRD-bearing Application (cert-manager, metallb, etc.) can cascade-delete its CRDs and all dependent resources. Don't delete those Applications directly; `crds.keep: true` only protects against `helm uninstall`
- cert-manager operator is ArgoCD-managed via the jetstack chart (was a manual `helm install` until migrated) — the `cert-manager` app must apply before `cert-manager-config` so CRDs exist before the ClusterIssuer; bootstrap.sh orders them correctly, and the config app self-heals if it races ahead
- ArgoCD can show a permanent `OutOfSync` (app still Healthy) when the kube-apiserver defaults a field the Helm chart doesn't template — e.g. `hostUsers: true` on Deployments (v1.32 user-namespace defaulting). It's cosmetic, not real drift; a sync won't fix it because the apiserver re-adds the field. Fix with an `ignoreDifferences` entry on that jsonPointer (see `infrastructure/headlamp/argocd-app-headlamp.yaml` → `/spec/template/spec/hostUsers` for the pattern)
- Cloud-init `users:` list must NOT include `- default` alongside an explicit `- name: ubuntu` — on Ubuntu cloud images the default user is already `ubuntu`, so the two definitions collide and `lock_passwd` / `chpasswd` / `ssh_pwauth` silently fail to apply, locking you out of the VM (no password, sometimes no key). Define `ubuntu` explicitly with no `- default` entry. Applies to every cloud-init snippet (`k8s-init.yaml`, `postgres-init.yaml`, etc.)
- Cloud-init `chpasswd: { list: ... }` is deprecated and silently no-ops on the cloud-init shipped with Ubuntu 24.04 — the password never gets set, so console/password login fails even though SSH-key login still works (this is why the k8s VMs always worked by key but not by password). Use the modern form: `chpasswd: { expire: false, users: [{name: ubuntu, password: ubuntu, type: text}] }`. User/password modules only run once per instance, so an already-booted VM needs a fresh clone to pick up a snippet change
- ArgoCD apps that pull a **remote Helm chart with inline `spec.source.helm.values`** (e.g. `monitoring`, `authentik`) render from the live Application CR, NOT from git — editing the `argocd-app-*.yaml` in git is a silent no-op until you `kubectl apply -f` the Application manifest (then ArgoCD re-renders + auto-syncs). Apps whose `source` is a git directory of plain manifests (e.g. `vaultwarden`) DO sync straight from git on push. Different mechanisms — don't assume a git push is enough
- Grafana OAuth via kube-prometheus-stack: the bundled grafana chart consumes env through `grafana.env` (map) + `grafana.envValueFrom` (map, for secretKeyRef) — `extraEnvVars` / `envFromSecrets` (Bitnami-style) are silently ignored. Authentik's `authorize`/`token`/`userinfo` endpoints are global (`https://auth.yanatech.co.uk/application/o/authorize/`); only discovery/jwks/`end-session` are slug-scoped (`/application/o/grafana/...`). Role mapping reads the `groups` claim (carried by the default `profile` scope): `contains(groups, 'authentik Admins') && 'Admin' || 'Viewer'`. Client ID/secret live in `grafana-authentik-secret` (keys `client_id`/`client_secret`)
- ArgoCD SSO via Authentik OIDC uses Dex (argocd-dex-server). Authentik app slug `argo-cd`; clientID/secret in `argocd-secret` key `dex.authentik.clientSecret` (patched manually, not in git). Dex config in `infrastructure/argocd/values.yaml` (`configs.cm.dex.config`): issuer `https://auth.yanatech.co.uk/application/o/argo-cd/`, scopes `openid profile email groups`, `insecureEnableGroups: true`. RBAC: `g, authentik Admins, role:admin` + `scopes: '[groups]'` in `configs.rbac`. Redirect URIs in Authentik (strict, both required): `https://argocd.yanatech.co.uk/api/dex/callback` and `https://localhost:8085/auth/callback`
- argo-cd Helm chart 9.x ingress quirks (all three silent-ignore traps hit in practice): (1) `server.ingress.hosts` (list) is ignored — use `server.ingress.hostname` (singular string) for the primary rule host. (2) `server.ingress.tls` (list) is ignored — the chart interprets any non-false value as "enable TLS" and generates a TLS entry pointing at its default secret `argocd-server-tls` (which doesn't exist → nginx fake cert). Use `server.ingress.extraTls` (list of `{hosts, secretName}`) for a custom TLS secret. (3) `server.ingress.ingressClassName` must be set explicitly — it doesn't inherit from a cluster default. Pattern that works: `hostname: argocd.yanatech.co.uk` + `extraTls: [{hosts: [argocd.yanatech.co.uk], secretName: wildcard-yanatech-tls}]`; no `hosts:` or `tls:` list
- pgAdmin4 OAuth2 via Authentik: the chart has no `config_local.py` support in Helm values — mount it via `extraConfigmapMounts` from a manually-created ConfigMap. Client ID/secret must be literal values in `config_local.py` (no env-var substitution). Three required keys beyond the basics: `OAUTH2_SERVER_METADATA_URL` (slug-scoped discovery endpoint, e.g. `/application/o/pgadmin/.well-known/openid-configuration`), `OAUTH2_API_BASE_URL` (must be slug-scoped, e.g. `/application/o/pgadmin/`, NOT root Authentik URL), and `OAUTH2_JWKS_URI` (`/application/o/pgadmin/jwks/`). Without `OAUTH2_SERVER_METADATA_URL` pgAdmin fails with `Missing "jwks_uri" in metadata`
- Headlamp SSO via Authentik is blocked by an upstream Headlamp bug (affects 0.42.0): `refreshing token: oauth2: token expired and refresh token is not set` — login succeeds but Headlamp immediately tries to refresh the token, finds no refresh token, and bounces back to the login page. Adding `offline_access` scope does not resolve it. Known issue affecting multiple OIDC providers (GitHub issues #3884, #4789, #4876, #5025). Workaround pending upstream fix
