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
| CNI | Cilium 1.17.3 (native routing, kube-proxy replacement, Hubble enabled) |
| Ceph CSI | ceph-csi-rbd (namespace: ceph-csi-rbd) |
| Default StorageClass | ceph-rbd |
| Load balancer | MetalLB |
| Ingress | ingress-nginx (2 replicas) |
| TLS | cert-manager + Let's Encrypt (DNS-01 via Cloudflare) |
| Monitoring | kube-prometheus-stack |
| Log aggregation | Loki + Promtail |
| SSO | Authentik |
| GitOps | ArgoCD v3.4.2 |
| Message broker | Apache Kafka 4.2.0 (Strimzi 1.0.0, KRaft mode) |
| Password manager | Vaultwarden |
| Backups | Velero → Backblaze B2 |
| Secret replication | Reflector |
| Config auto-reload | Stakater Reloader |
| Node reboots | Kured 1.22.0 |
| Push notifications | Gotify 2.6.3 |
| Photo library | Immich — removed, pending fresh deploy with CNPG vchord support |
| Resource recommendations | Goldilocks v4.14.1 |
| Database | CloudNativePG 1.29.1 (pg-main: 3-instance PG18 cluster) |
| CI runners | Actions Runner Controller (gha-runner-scale-set 0.9.3) |
| Container registry | Harbor v2.15.1 |
| Pod rebalancing | Descheduler 0.36.0 |

### kubectl Access
```bash
ssh ubuntu@192.168.22.21
kubectl get nodes
```

---

## Cilium (CNI)

Replaced Flannel on 2026-06-04. Runs in native routing mode leveraging the existing flat L2 network (`192.168.22.0/24`) between all k8s VMs via `vmbr0`.

- **Version:** 1.17.3
- **Mode:** Native routing (no VXLAN/overlay)
- **kube-proxy:** fully replaced by Cilium eBPF
- **Interface:** `eth0` on all k8s nodes
- **Pod CIDR:** `10.244.0.0/16` (IPAM: cluster-pool)
- **k8s API:** `192.168.22.21:6443` (cp-1 direct — no kube-vip VIP)
- **Namespace:** `kube-system`
- **Manifest:** `infrastructure/cilium/argocd-app-cilium.yaml`

### Hubble (traffic visibility)
- **URL:** `https://hubble.yanatech.co.uk`
- Relay connected to all 6 nodes on port 4244
- UI ingress via ingress-nginx + `wildcard-yanatech-tls`

---

## Networking

### MetalLB
- **IP Pool:** `192.168.22.200 - 192.168.22.249` (pool name: `k8s-pool`, 50 IPs)
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
- Kafka UI (Provectus): https://kafka-ui.yanatech.co.uk (Authentik SSO via forward auth)

---

## Log Aggregation (Loki + Promtail)

Cluster-wide log aggregation deployed into the `monitoring` namespace alongside kube-prometheus-stack. Promtail runs as a DaemonSet on all nodes (workers + control plane) and ships logs to Loki. Loki is wired into Grafana as an additional datasource.

- **Loki:** Helm chart `grafana/loki` 6.30.1, `deploymentMode: SingleBinary`, 1 replica, 20Gi ceph-rbd PVC
- **Promtail:** Helm chart `grafana/promtail` 6.16.6, DaemonSet with control-plane toleration
- **Namespace:** `monitoring`
- **Loki internal endpoint:** `http://loki.monitoring.svc.cluster.local:3100`
- **Grafana datasource:** Loki, proxy mode, non-default

### Manifests
```
infrastructure/loki/argocd-app-loki.yaml
infrastructure/loki/argocd-app-promtail.yaml
```

### Useful LogQL queries
```logql
# All ingress traffic
{namespace="ingress-nginx"}

# Traffic to a specific site
{namespace="ingress-nginx"} |= "yanatech.co.uk"

# Specific namespace logs
{namespace="vaultwarden"}
{namespace="authentik"}
{namespace="kafka"}

# Errors across the cluster
{namespace=~".+"} |= "error" | logfmt
```

### Notes
- Loki 6.x chart requires `deploymentMode: SingleBinary` set explicitly plus `backend.replicas: 0`, `read.replicas: 0`, `write.replicas: 0` — without these the chart validator fires (`negative structured metadata bytes received` errors in Loki logs are cosmetic — ingestion still works)
- Promtail requires a toleration for `node-role.kubernetes.io/control-plane: NoSchedule` to run on control plane nodes
- Loki chart version must be specified as a valid published version — `kubectl apply` of the ArgoCD app will show `Unknown` sync status with a `ComparisonError` if the chart version doesn't exist
- Grafana dashboard ID **15141** (Loki Kubernetes Logs) provides a namespace-dropdown overview of all pod logs

---

## PostgreSQL (CloudNativePG)

**pg1 (VM 110) decommissioned 2026-06-04.** All databases now run in-cluster via CloudNativePG (CNPG). CNPG provides streaming replication, automatic failover, and Barman WAL archiving to Backblaze B2.

### pg-main Cluster

- **Namespace:** `cnpg-clusters`
- **Instances:** 3 (primary on pg-main-1, standbys on pg-main-2/3, one per worker node)
- **Image:** `ghcr.io/cloudnative-pg/postgresql:18` (standard — no custom extensions needed for current databases)
- **Storage:** 50Gi ceph-rbd per instance
- **CNPG operator:** `cnpg-system` namespace, chart `cloudnative-pg` v1.29.1
- **Manifest:** `infrastructure/cnpg-clusters/`

### Services

| Service | FQDN | Purpose |
|---|---|---|
| pg-main-rw | `pg-main-rw.cnpg-clusters.svc.cluster.local:5432` | Primary (read/write) — all apps connect here |
| pg-main-ro | `pg-main-ro.cnpg-clusters.svc.cluster.local:5432` | Read-only replicas |
| pg-main-r | `pg-main-r.cnpg-clusters.svc.cluster.local:5432` | Any instance |

### Databases / Roles

| Database | Owner role | Used by |
|---|---|---|
| vaultwarden | vaultwarden | Vaultwarden ✅ (migrated from pg1 2026-06-04) |
| authentik | authentik | Authentik ✅ (migrated from pg1 2026-06-04) |
| nextcloud | nextcloud | Nextcloud ✅ (migrated from pg1 2026-06-04) |

- Role passwords stored in Vaultwarden
- Immich removed 2026-06-04 — pending fresh deploy once CNPG vchord/GLIBC issue resolved

### Backups (Barman → Backblaze B2)

- **Bucket:** `yanatech-cnpg`
- **Endpoint:** `https://s3.eu-central-003.backblazeb2.com`
- **WAL archiving:** continuous, gzip compressed
- **Base backups:** scheduled daily at 02:00 via `ScheduledBackup` CRD
- **Retention:** 7 days
- **B2 credentials:** `cnpg-b2-credentials` secret in `cnpg-clusters` namespace (stored in Vaultwarden as `cnpg-b2-credentials`)

### Bootstrap prerequisites (manually created, not in git)
```bash
kubectl create namespace cnpg-clusters

kubectl create secret generic cnpg-b2-credentials \
  --namespace cnpg-clusters \
  --from-literal=ACCESS_KEY_ID='<keyID>' \
  --from-literal=ACCESS_SECRET_KEY='<applicationKey>'

kubectl create secret docker-registry harbor-pull-secret \
  --namespace cnpg-clusters \
  --docker-server=harbor.yanatech.co.uk \
  --docker-username='robot$cnpg-pull' \
  --docker-password='<robot-secret>'

# After cluster is up, create roles and databases:
kubectl exec -it -n cnpg-clusters pg-main-1 -- psql -U postgres
# CREATE ROLE vaultwarden WITH LOGIN PASSWORD '...';
# CREATE ROLE authentik WITH LOGIN PASSWORD '...';
# CREATE ROLE nextcloud WITH LOGIN PASSWORD '...';
# CREATE DATABASE vaultwarden OWNER vaultwarden;
# CREATE DATABASE authentik OWNER authentik;
# CREATE DATABASE nextcloud OWNER nextcloud;
```

### Cloud-init Snippet (historical — pg1 decommissioned 2026-06-04)
Retained for reference only. pg1 was VM 110 (192.168.22.40), PostgreSQL 18.4, HA-managed on pve1.

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
- **Connected to:** CNPG pg-main (`pg-main-rw.cnpg-clusters.svc.cluster.local`) — vaultwarden, authentik, nextcloud databases

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

## Nextcloud

Self-hosted cloud storage, accessible at `https://cloud.yanatech.co.uk`. Database on pg1, files on ceph-rbd PVC.

- **Namespace:** `nextcloud`
- **Helm chart:** `nextcloud` from `https://nextcloud.github.io/helm/`, version `6.6.10`
- **Image:** `nextcloud:30.0.10-fpm` + nginx sidecar
- **Database:** pg1 (`192.168.22.40`), database `nextcloud`, role `nextcloud`
- **Storage:** 100Gi ceph-rbd PVC (`nextcloud-nextcloud`)
- **Auth:** Authentik SSO (user_oidc app) + local admin fallback (`admin`)
- **Credentials secret:** `nextcloud-secret` in `nextcloud` namespace (stored in Vaultwarden)

### Bootstrap prerequisites (manually created, not in git)
```bash
# On pg1
sudo -u postgres psql <<SQL
CREATE ROLE nextcloud WITH LOGIN PASSWORD '<db-password>';
CREATE DATABASE nextcloud OWNER nextcloud;
SQL

# On k8s-cp-1
kubectl create namespace nextcloud
kubectl create secret generic nextcloud-secret \
  --namespace nextcloud \
  --from-literal=nextcloud-username='admin' \
  --from-literal=nextcloud-password='<admin-password>' \
  --from-literal=nextcloud-token='<random-32-char-hex>' \
  --from-literal=db-username='nextcloud' \
  --from-literal=db-password='<db-password>'
```

Generate passwords: `openssl rand -hex 16`

### Notes
- Deployment strategy must allow for init container (`extraInitContainers`) to `chown -R 33:33 /var/www/html` — without this the installer cannot write `config.php`
- `trusted_domains` defaults to `localhost` only — set via `configs.proxy.config.php` in values or `php occ config:system:set trusted_domains 1 --value=cloud.yanatech.co.uk`
- `nginx.ingress.kubernetes.io/server-snippet` is blocked by ingress-nginx — CalDAV/CardDAV redirects handled inside Nextcloud instead
- `proxy-body-size: "0"` required for large file uploads
- Authentik SSO via `user_oidc` app: install with `php occ app:install user_oidc`, configure with `php occ user_oidc:provider authentik --clientid=... --clientsecret=... --discoveryuri=https://auth.yanatech.co.uk/application/o/nextcloud/.well-known/openid-configuration --unique-uid=0 --mapping-uid=preferred_username`
- `allow_local_remote_servers` must be set to `true` in config — Nextcloud blocks outbound requests to RFC1918 addresses by default, which breaks OIDC discovery when Authentik resolves to the MetalLB VIP (`192.168.22.200`). Set via `php occ config:system:set allow_local_remote_servers --value=true --type=boolean` or in `configs.proxy.config.php`

---

## Immich

Self-hosted photo and video library with ML features (face recognition, semantic search, duplicate detection). Accessible at `https://photos.yanatech.co.uk`.

- **Namespace:** `immich`
- **Helm chart:** OCI `ghcr.io/immich-app/immich-charts/immich` version `0.12.0` (app v2.6.3)
- **Components:** immich-server, immich-machine-learning, valkey (in-cluster cache)
- **Database:** pg1 (`192.168.22.40`), database `immich`, role `immich`
- **Storage:** 500Gi ceph-rbd PVC (`immich-library`) for photos/videos
- **Auth:** Authentik SSO (OAuth2) + local admin fallback
- **URL:** `https://photos.yanatech.co.uk`
- **Credentials secret:** `immich-secret` in `immich` namespace (key: `db-url`)
- **Manifest:** `apps/immich/argocd-app-immich.yaml`

### pg1 prerequisites (must be done before deploying)
```bash
# Install extensions on pg1 (one-time setup, already done)
sudo apt install -y postgresql-18-pgvector
wget https://github.com/tensorchord/VectorChord/releases/download/1.1.1/postgresql-18-vchord_1.1.1-1_$(dpkg --print-architecture).deb
sudo apt install -y ./postgresql-18-vchord_1.1.1-1_$(dpkg --print-architecture).deb
sudo -u postgres psql -c "ALTER SYSTEM SET shared_preload_libraries = 'vchord.so';"
sudo systemctl restart postgresql

# Create role, database and extensions
sudo -u postgres psql -c "CREATE ROLE immich WITH LOGIN PASSWORD '<password>';"
sudo -u postgres psql -c "CREATE DATABASE immich OWNER immich;"
sudo -u postgres psql -d immich -c "CREATE EXTENSION IF NOT EXISTS cube;"
sudo -u postgres psql -d immich -c "CREATE EXTENSION IF NOT EXISTS earthdistance;"
sudo -u postgres psql -d immich -c "CREATE EXTENSION IF NOT EXISTS vector;"
sudo -u postgres psql -d immich -c "CREATE EXTENSION IF NOT EXISTS vchord;"
```

### K8s bootstrap prerequisites
```bash
kubectl create namespace immich

# Pre-create library PVC before ArgoCD sync
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: immich-library
  namespace: immich
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ceph-rbd
  resources:
    requests:
      storage: 500Gi
EOF

kubectl create secret generic immich-secret \
  --namespace immich \
  --from-literal=db-url='postgresql://immich:<password>@192.168.22.40:5432/immich'
```

Generate password: `openssl rand -hex 16`

### Notes
- The immich Helm chart (0.10.0+) removed the bundled postgresql subchart — do not set `postgresql.enabled: false` in values, it will cause a template error. Simply omit the `postgresql:` key entirely
- DB env vars go under `server.controllers.main.containers.main.env` — the top-level `env:` key and `server.env:` are silently ignored
- `cube` and `earthdistance` extensions require superuser to create — must be done as postgres superuser before Immich starts, not by the `immich` role
- VectorChord 1.1.1 is compatible with Immich (accepted range >= 0.3, < 2.0)
- pgvector 0.8.2 is compatible (required range >= 0.7, < 0.9)
- Authentik SSO via OAuth2: configure in Immich admin UI → Authentication → OAuth. Redirect URIs (all required): `https://photos.yanatech.co.uk/auth/login`, `https://photos.yanatech.co.uk/user-settings`, `app.immich:///oauth-callback`. Issuer URL: `https://auth.yanatech.co.uk/application/o/immich/`

---

## Gotify

Push notification server for cluster alerts. Alertmanager sends to a bridge (`alertmanager-gotify-bridge`) which translates to Gotify's API format.

- **Namespace:** `gotify`
- **Image:** `gotify/server:2.6.3`
- **URL:** `https://gotify.yanatech.co.uk`
- **Storage:** 1Gi ceph-rbd PVC
- **Credentials secret:** `gotify-secret` in `gotify` namespace (stored in Vaultwarden)
- **Manifests:** `apps/gotify/manifests/gotify.yaml`

### Alertmanager integration
- Bridge: `druggeri/alertmanager_gotify_bridge:latest` — translates Alertmanager webhook payload to Gotify API
- Bridge endpoint: `http://alertmanager-gotify-bridge.gotify.svc.cluster.local/gotify_webhook`
- Alertmanager webhook URL points to the bridge; bridge forwards to `http://gotify.gotify.svc.cluster.local/message`
- App token stored in Alertmanager config values and bridge env (`GOTIFY_TOKEN`)
- Watchdog + InfoInhibitor alerts routed to null receiver — everything else goes to Gotify
- Reboot window 04:00-06:00 to avoid overlap with pg1 backup (02:30) and Proxmox backup (03:30)

### Notes
- Alertmanager's generic webhook sends a different JSON structure than Gotify's API expects — the bridge is mandatory
- `GOTIFY_ENDPOINT` must include `/message` (e.g. `http://gotify.gotify.svc.cluster.local/message`)
- Bridge listens on `/gotify_webhook` not `/`
- etcd, kube-proxy, kube-scheduler, kube-controller-manager alerts silenced for 1 year — these are false positives in kubeadm clusters where those components aren't scraped by Prometheus

---

## Stakater Reloader

Watches ConfigMaps and Secrets and automatically rolls dependent Deployments/StatefulSets/DaemonSets when they change. Eliminates manual `kubectl rollout restart` after secret rotation.

- **Namespace:** `reloader`
- **Helm chart:** `stakater/reloader` 2.2.12
- **Watches:** all namespaces
- **Manifest:** `infrastructure/reloader/argocd-app-reloader.yaml`

### Annotating workloads
```yaml
# Restart when any referenced secret/configmap changes (auto-detect)
annotations:
  reloader.stakater.com/auto: "true"

# Restart only when a specific secret changes
annotations:
  secret.reloader.stakater.com/reload: "my-secret"

# Restart only when a specific configmap changes
annotations:
  configmap.reloader.stakater.com/reload: "my-configmap"
```

Currently annotated: `vaultwarden` deployment (`secret.reloader.stakater.com/reload: "vaultwarden-secret"`)

---

## Kured

Kubernetes Reboot Daemon — watches for `/var/run/reboot-required` on each node (created by Ubuntu's `unattended-upgrades` after kernel updates) and safely reboots nodes one at a time, draining pods first.

- **Namespace:** `kured`
- **Helm chart:** `kubereboot/kured` 5.12.0 (app version 1.22.0)
- **Mode:** DaemonSet — one pod per node (6 total: 3 control plane + 3 workers)
- **Reboot window:** 04:00–06:00 Europe/London (avoids pg1 backup at 02:30 and Proxmox backup at 03:30)
- **Reboot delay:** 60s between nodes
- **Notifications:** Gotify via `notifyUrl`
- **Manifest:** `infrastructure/kured/argocd-app-kured.yaml`
- Toleration for `node-role.kubernetes.io/control-plane: NoSchedule` — runs on all nodes

---

## Velero Backups

- **Backend:** Backblaze B2
- **Bucket:** `yanatech-velero`
- **Endpoint:** `s3.eu-central-003.backblazeb2.com`
- **Schedule:** Daily at 2am UTC ✅ live (verified 2026-06-01)
- **Retention:** 30 days
- **Namespaces backed up:** vaultwarden, authentik, monitoring, kafka, ingress-nginx, cert-manager, argocd, nextcloud, pgadmin, immich
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

## Harbor (Private Container Registry)

Private container registry for all homelab and product images. Replaces `ghcr.io` for product microservices — all CI builds push here.

- **Namespace:** `harbor`
- **Version:** v2.15.1
- **URL:** `https://harbor.yanatech.co.uk`
- **Helm chart:** `harbor/harbor` from `https://helm.goharbor.io`
- **Auth:** Authentik OIDC + local admin fallback
- **Manifest:** `infrastructure/harbor/argocd-app-harbor.yaml`
- **Credentials secret:** `harbor-secret` in `harbor` namespace (stored in Vaultwarden)

### Storage (ceph-rbd PVCs)

| PVC | Size | Purpose |
|---|---|---|
| registry | 100Gi | Image blob storage |
| database | 10Gi | Internal PostgreSQL |
| jobservice | 10Gi | Job logs |
| redis | 5Gi | Cache |
| trivy | 10Gi | Vulnerability scan cache |

### Projects

| Project | Access | Purpose |
|---|---|---|
| library | Public | Default Harbor project |
| infra | Private | CNPG custom image, internal tools |
| yana-forex | Private | Forex platform microservice images |
| yana-ecommerce | Private | E-commerce microservice images |

### Authentik OIDC

- Slug: `harbor`
- Redirect URI: `https://harbor.yanatech.co.uk/c/oidc/callback`
- Scopes: `openid`, `profile`, `email`
- OIDC endpoint: `https://auth.yanatech.co.uk/application/o/harbor/`
- Auto-onboard: enabled (`oidc_auto_onboard: true`)
- Admin group: `authentik Admins`
- OIDC credentials: stored in Vaultwarden as `harbor-oidc`

### Bootstrap prerequisites (manually created, not in git)
```bash
kubectl create namespace harbor

kubectl create secret generic harbor-secret \
  --namespace harbor \
  --from-literal=HARBOR_ADMIN_PASSWORD='<admin-password>' \
  --from-literal=HARBOR_SECRET_KEY='<secret-key>' \
  --from-literal=secretKey='<secret-key>'
```

Note: `secretKey` and `HARBOR_SECRET_KEY` must both be present with the same value — the chart mounts `secretKey` as a file volume and reads `HARBOR_ADMIN_PASSWORD` as an env var. Missing either key causes harbor-core to fail to start.

### Direct admin login URL
`https://harbor.yanatech.co.uk/account/sign-in?redirect_url=/harbor/projects` — use this when OIDC is the default auth mode and you need to log in as `admin`.

---

## Actions Runner Controller (CI on-LAN)

Self-hosted GitHub Actions runners running inside the cluster. Builds happen on-LAN and push directly to Harbor. Uses the new ARC (gha-runner-scale-set) not the legacy summerwind ARC.

- **Namespace:** `actions-runner`
- **Controller chart:** `gha-runner-scale-set-controller` from `oci://ghcr.io/actions/actions-runner-controller-charts` (version 0.9.3)
- **Runner chart:** `gha-runner-scale-set` from same OCI registry
- **Manifest:** `infrastructure/actions-runner/`
- **PAT secret:** `github-pat` in `actions-runner` namespace (stored in Vaultwarden as `github-actions-runner-pat`)

### Runner Sets

| Runner Set | Repo | Min | Max | Listener |
|---|---|---|---|---|
| runners-k8s-apps | akann/k8s-apps | 0 | 4 | Running |
| runners-yana-forex | akann/yana-forex | 0 | 4 | Running |
| runners-yana-ecommerce | akann/yana-ecommerce | 0 | 4 | Running |

- Runners scale from 0 → max on job queue, back to 0 when idle
- Each runner: 1-2 CPU, 2-4Gi RAM, scheduled on workers only
- `controllerServiceAccount.name: actions-runner-controller-gha-rs-controller` must be set explicitly in each runner set — auto-discovery fails

### Bootstrap prerequisites
```bash
kubectl create namespace actions-runner

kubectl create secret generic github-pat \
  --namespace actions-runner \
  --from-literal=github_token='<PAT from Vaultwarden>'
```

### Using runners in workflows
```yaml
# .github/workflows/build.yaml
jobs:
  build:
    runs-on: runners-k8s-apps   # matches runner set name
```

---

## Infisical (Secrets Manager)

Self-hosted secrets manager. All Kubernetes bootstrap secrets stored here. ESO pulls secrets from Infisical into k8s native Secrets automatically.

- **Namespace:** `infisical`
- **URL:** `https://infisical.yanatech.co.uk`
- **Helm chart:** `infisical-standalone` from `https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/`
- **Auth:** Email/password (OIDC SSO requires paid license)
- **Database:** CNPG pg-main (`infisical` database)
- **Cache:** Redis (bundled, ceph-rbd 5Gi PVC)
- **Manifest:** `infrastructure/infisical/argocd-app-infisical.yaml`
- **Admin credentials:** stored in Vaultwarden as `infisical-admin`
- **Organisation:** `yanatech`
- **Project:** `k8s-homelab` (slug: `k8s-homelab`, ID: `69b39965-b778-47a7-ba52-2cd66a7aad0a`)
- **Environment:** `prod`

### Secret folder structure (`prod` environment)

| Folder | Secrets |
|---|---|
| `/ceph-csi-rbd` | userID, userKey |
| `/cert-manager` | api-token |
| `/monitoring` | client_id, client_secret (Grafana Authentik OIDC) |
| `/authentik` | AUTHENTIK_POSTGRESQL__HOST/NAME/PASSWORD/USER, AUTHENTIK_REDIS__HOST, AUTHENTIK_SECRET_KEY |
| `/argocd` | dex.authentik.clientSecret |
| `/vaultwarden` | DATABASE_URL, ADMIN_TOKEN, DOMAIN, SIGNUPS_ALLOWED |
| `/velero` | aws_access_key_id, aws_secret_access_key |
| `/pgadmin` | OAUTH2_CLIENT_ID, OAUTH2_CLIENT_SECRET |
| `/nextcloud` | db-host, db-password, db-username, nextcloud-password, nextcloud-token, nextcloud-username |
| `/gotify` | admin-password |
| `/cnpg-clusters` | ACCESS_KEY_ID, ACCESS_SECRET_KEY, harbor-robot-username, harbor-robot-password |
| `/harbor` | HARBOR_ADMIN_PASSWORD, secretKey |
| `/actions-runner` | github_token |
| `/infisical` | ENCRYPTION_KEY, AUTH_SECRET, DB_CONNECTION_URI |
| `/immich` | (reserved for future Immich redeploy) |

### SMTP configuration
- Host: `smtppro.zoho.eu`, Port: `465`, From: `akan@yanatech.org`
- Credentials in Vaultwarden as `infisical-smtp`
- Passed via `infisical-secrets` k8s secret (all env vars via `envFrom: secretRef`)

### Bootstrap prerequisites
```bash
kubectl create namespace infisical

# Create role + database on pg-main first
kubectl exec -it -n cnpg-clusters pg-main-1 -- psql -U postgres -c \
  "CREATE ROLE infisical WITH LOGIN PASSWORD '<password>'; CREATE DATABASE infisical OWNER infisical;"

kubectl create secret generic infisical-secrets \
  --namespace infisical \
  --from-literal=ENCRYPTION_KEY='<from Vaultwarden infisical-secrets>' \
  --from-literal=AUTH_SECRET='<from Vaultwarden infisical-secrets>' \
  --from-literal=DB_CONNECTION_URI='postgresql://infisical:<password>@pg-main-rw.cnpg-clusters.svc.cluster.local:5432/infisical' \
  --from-literal=SMTP_HOST='smtppro.zoho.eu' \
  --from-literal=SMTP_USERNAME='akan' \
  --from-literal=SMTP_PASSWORD='<from Vaultwarden infisical-smtp>' \
  --from-literal=SMTP_PORT='465' \
  --from-literal=SMTP_FROM_ADDRESS='akan@yanatech.org' \
  --from-literal=SMTP_FROM_NAME='Infisical'
```

---

## ESO (External Secrets Operator)

Pulls secrets from Infisical into Kubernetes native Secrets automatically.

- **Namespace:** `external-secrets`
- **Helm chart:** `external-secrets/external-secrets`
- **Manifest:** `infrastructure/eso/argocd-app-eso.yaml`
- **ClusterSecretStore:** `infisical` (Valid, ReadOnly) — `infrastructure/eso/cluster-secret-store.yaml`
- **API version:** `external-secrets.io/v1` (not v1beta1)
- **Machine identity:** `eso-k8s` (Universal Auth) — credentials in `infisical-eso-credentials` secret in `external-secrets` namespace, stored in Vaultwarden as `infisical-eso-machine-identity`

### Bootstrap prerequisites
```bash
kubectl create secret generic infisical-eso-credentials \
  --namespace external-secrets \
  --from-literal=clientId='<from Vaultwarden infisical-eso-machine-identity>' \
  --from-literal=clientSecret='<from Vaultwarden infisical-eso-machine-identity>'
```

### ExternalSecret pattern
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: <secret-name>
  namespace: <namespace>
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: infisical
    kind: ClusterSecretStore
  target:
    name: <secret-name>
    creationPolicy: Owner
  data:
    - secretKey: <k8s-key>
      remoteRef:
        key: /<folder>/<INFISICAL_KEY>
```

---

## Installed Services

| Service | Namespace | URL | Managed by |
|---|---|---|---|
| Cilium | kube-system | - | ArgoCD |
| Hubble UI | kube-system | https://hubble.yanatech.co.uk | ArgoCD |
| Harbor | harbor | https://harbor.yanatech.co.uk | ArgoCD |
| Actions Runner Controller | actions-runner | - | ArgoCD |
| CloudNativePG | cnpg-system | - | ArgoCD |
| CNPG pg-main cluster | cnpg-clusters | - | ArgoCD |
| ESO | external-secrets | - | ArgoCD |
| Infisical | infisical | https://infisical.yanatech.co.uk | ArgoCD |
| ingress-nginx | ingress-nginx | - | ArgoCD |
| MetalLB | metallb-system | - | ArgoCD |
| cert-manager | cert-manager | - | ArgoCD |
| Reflector | kube-system | - | ArgoCD |
| Ceph CSI RBD | ceph-csi-rbd | - | ArgoCD |
| Prometheus+Grafana | monitoring | https://grafana.yanatech.co.uk | ArgoCD |
| Loki | monitoring | - | ArgoCD |
| Promtail | monitoring | - | ArgoCD |
| ArgoCD | argocd | https://argocd.yanatech.co.uk | Helm |
| Authentik | authentik | https://auth.yanatech.co.uk | ArgoCD |
| Vaultwarden | vaultwarden | https://vault.yanatech.co.uk | ArgoCD |
| Kafka | kafka | - | ArgoCD |
| Kafka UI | kafka | https://kafka-ui.yanatech.co.uk | ArgoCD |
| Velero | velero | - | ArgoCD |
| Uptime Kuma | uptime-kuma | https://status.yanatech.co.uk | ArgoCD |
| Headlamp | headlamp | https://headlamp.yanatech.co.uk | ArgoCD |
| pgAdmin4 | pgadmin | https://pgadmin.yanatech.co.uk | ArgoCD |
| Nextcloud | nextcloud | https://cloud.yanatech.co.uk | ArgoCD |
| Gotify | gotify | https://gotify.yanatech.co.uk | ArgoCD |
| Reloader | reloader | - | ArgoCD |
| Kured | kured | - | ArgoCD |
| Goldilocks | goldilocks | https://goldilocks.yanatech.co.uk | ArgoCD |
| Descheduler | kube-system | - | ArgoCD |
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
│   ├── nextcloud/           ✅ deployed
│   ├── gotify/              ✅ deployed
│   └── immich/              ✅ deployed
└── infrastructure/
    ├── metallb/             ✅ deployed
    ├── cert-manager/        ✅ deployed
    ├── ingress-nginx/       ✅ deployed
    ├── monitoring/          ✅ deployed
    ├── authentik/           ✅ deployed
    ├── reflector/           ✅ deployed
    ├── ceph-csi/            ✅ deployed
    ├── headlamp/            ✅ deployed
    ├── velero/              ✅ deployed
    ├── loki/                ✅ deployed
    ├── reloader/            ✅ deployed
    ├── kured/               ✅ deployed
    ├── goldilocks/          ✅ deployed
    └── descheduler/         ✅ deployed
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
#    - nextcloud-secret in nextcloud (nextcloud-username, nextcloud-password, nextcloud-token, db-username, db-password)
#    - immich-secret in immich (db-url as postgresql://immich:<password>@192.168.22.40:5432/immich)
#    - immich-library PVC (500Gi ceph-rbd) must be created before ArgoCD syncs immich
# 3. Run bootstrap script:
bash bootstrap.sh
```

### Manual Secrets Reference

**Note: All secrets below are now stored in Infisical and will be replaced by ExternalSecret CRDs (in progress). On a fresh cluster, ESO + Infisical must be bootstrapped first, then ExternalSecrets will create these automatically.**

| Secret | Namespace | Contents | Infisical path |
|---|---|---|---|
| `csi-rbd-secret` | ceph-csi-rbd | Ceph userID + userKey | `/ceph-csi-rbd` |
| `cloudflare-api-token` | cert-manager | Cloudflare API token | `/cert-manager` |
| `grafana-authentik-secret` | monitoring | Authentik OAuth client_id + client_secret | `/monitoring` |
| `authentik-secret` | authentik | DB creds, Redis host, secret key | `/authentik` |
| `vaultwarden-secret` | vaultwarden | DATABASE_URL, ADMIN_TOKEN, DOMAIN, SIGNUPS_ALLOWED | `/vaultwarden` |
| `velero-b2-credentials` | velero | Backblaze B2 keyID + applicationKey | `/velero` |
| `pgadmin-oauth-secret` | pgadmin | Authentik OAuth2 client ID + secret | `/pgadmin` |
| `nextcloud-secret` | nextcloud | nextcloud-username/password/token, db-username/password/host | `/nextcloud` |
| `gotify-secret` | gotify | admin-password | `/gotify` |
| `immich-secret` | immich | db-url (for future redeploy) | `/immich` |
| `cnpg-b2-credentials` | cnpg-clusters | ACCESS_KEY_ID, ACCESS_SECRET_KEY | `/cnpg-clusters` |
| `harbor-pull-secret` | cnpg-clusters | docker-registry (robot$cnpg-pull) | `/cnpg-clusters` |
| `harbor-secret` | harbor | HARBOR_ADMIN_PASSWORD, secretKey | `/harbor` |
| `github-pat` | actions-runner | github_token | `/actions-runner` |
| `argocd-secret` (patch) | argocd | dex.authentik.clientSecret | `/argocd` |
| `infisical-secrets` | infisical | ENCRYPTION_KEY, AUTH_SECRET, DB_CONNECTION_URI, SMTP_* | `/infisical` |
| `infisical-eso-credentials` | external-secrets | clientId, clientSecret (machine identity) | Vaultwarden only |

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
- ServiceMonitor: `apps/yanatech/service-monitor.yaml` scrapes `/api/health` every 30s (label `release: kube-prometheus-stack` required)

---

## Pending / TODO

- [x] Dedicated PostgreSQL VM on Proxmox for shared database (VM 110 — see PostgreSQL section)
- [x] Authentik SSO integration: Grafana ✅ (done 2026-05-31), ArgoCD ✅ (done 2026-06-01), Headlamp ⏳ (blocked by upstream Headlamp bug — OIDC refresh token not stored, running with token auth), pgAdmin4 ✅ (done 2026-06-01), Nextcloud ✅ (done 2026-06-02), Harbor ✅ (done 2026-06-04)
- [x] pgAdmin4 deployment with Authentik SSO (done 2026-06-01 — `apps/pgadmin/`, connected to CNPG pg-main)
- [x] Loki + Promtail log aggregation (done 2026-06-01 — `infrastructure/loki/`, wired into Grafana)
- [x] Nextcloud (done 2026-06-02 — `apps/nextcloud/`, on CNPG pg-main + ceph-rbd, accessible at `https://cloud.yanatech.co.uk`)
- [x] Gotify push notifications + Alertmanager integration (done 2026-06-02 — `apps/gotify/`, bridge at `alertmanager-gotify-bridge`)
- [x] Stakater Reloader (done 2026-06-02 — `infrastructure/reloader/`, watching all namespaces)
- [x] Kured automatic node reboots (done 2026-06-02 — `infrastructure/kured/`, window 04:00-06:00 Europe/London)
- [x] Goldilocks resource recommendations (done 2026-06-03 — `infrastructure/goldilocks/`, dashboard at `https://goldilocks.yanatech.co.uk`)
- [x] Descheduler pod rebalancing (done 2026-06-03 — `infrastructure/descheduler/`, runs every 5 minutes)
- [x] Move Vaultwarden database to CNPG (done 2026-06-04 — migrated from pg1 to pg-main-rw.cnpg-clusters)
- [x] Move Authentik database to CNPG (done 2026-06-04 — migrated from pg1 to pg-main-rw.cnpg-clusters)
- [x] Move Nextcloud database to CNPG (done 2026-06-04 — migrated from pg1 to pg-main-rw.cnpg-clusters)
- [x] Decommission pg1 VM 110 (done 2026-06-04 — all databases migrated, VM destroyed)
- [ ] Headlamp SSO — revisit when Headlamp 0.43.0+ ships with OIDC refresh token fix
- [ ] Immich — removed 2026-06-04, pending fresh deploy. Blocked by: CNPG vchord GLIBC issue (vchord 1.1.1 requires GLIBC_2.33, CNPG bootstrap uses GLIBC_2.31 Bullseye). Resolution: use CNPG 1.29 Image Catalog or build bookworm-based custom image correctly.
- [x] Cilium CNI (done 2026-06-04 — replaced Flannel, native routing mode, kube-proxy removed, Hubble enabled at `https://hubble.yanatech.co.uk`)
- [x] MetalLB pool expanded (done 2026-06-04 — `192.168.22.200-249`, 50 IPs)
- [x] Sync-wave annotations on all ArgoCD apps + bootstrap.sh ordering by wave (done 2026-06-04)
- [x] Harbor private container registry (done 2026-06-04 — `infrastructure/harbor/`, Authentik OIDC, projects: infra/yana-forex/yana-ecommerce)
- [x] Actions Runner Controller (done 2026-06-04 — `infrastructure/actions-runner/`, runner sets for k8s-apps/yana-forex/yana-ecommerce, scale 0→4)
- [x] CloudNativePG operator + pg-main cluster (done 2026-06-04 — `infrastructure/cnpg/`, 3-instance PG18, Barman B2 backups)
- [x] ESO + Infisical (done 2026-06-05 — `infrastructure/eso/` + `infrastructure/infisical/`, all 42 bootstrap secrets imported, ClusterSecretStore Valid)
- [ ] Write ExternalSecret CRDs for all namespaces (in progress — vaultwarden template created, remaining namespaces pending)

---

## Goldilocks

Resource recommendation dashboard — uses VPA in recommendation mode to suggest right-sized CPU/memory requests and limits for all deployments. Does not apply changes automatically.

- **Namespace:** `goldilocks`
- **Helm chart:** `fairwinds-stable/goldilocks` 10.3.0 (app v4.14.1)
- **URL:** `https://goldilocks.yanatech.co.uk`
- **Auth:** Authentik forward auth (proxy outpost `ak-outpost-goldilocks`)
- **Manifest:** `infrastructure/goldilocks/argocd-app-goldilocks.yaml`
- VPA installed as subchart in recommendation mode only — no automatic resource changes

### Enabling namespaces
Goldilocks only analyses namespaces with the label applied:
```bash
kubectl label namespace <namespace> goldilocks.fairwinds.com/enabled=true

# Currently enabled:
# vaultwarden, authentik, nextcloud, immich, gotify, monitoring, kafka, pgadmin
```

---

## Descheduler

Rebalances pods across nodes after rescheduling events (node reboots, drains, new nodes). Runs as a CronJob every 5 minutes. Evicts pods that can be scheduled on better-utilised nodes; the default scheduler handles rescheduling.

- **Namespace:** `kube-system`
- **Helm chart:** `descheduler/descheduler` 0.36.0
- **Schedule:** every 5 minutes (`*/5 * * * *`)
- **Manifest:** `infrastructure/descheduler/argocd-app-descheduler.yaml`
- Plugins enabled: `LowNodeUtilization`, `RemovePodsViolatingTopologySpreadConstraints`, `RemovePodsViolatingNodeAffinity`, `RemovePodsViolatingInterPodAntiAffinity`
- PVC pods and local storage pods are not evicted (`ignorePvcPods: true`)

---

## Known Issues / Notes

- `qm list` only shows local node VMs — use `pvesh get /cluster/resources --type vm` for all
- `qm set` / `qm start` for VMs on remote nodes must be run via `ssh pve2/pve3`
- CPU type must be `host` on all K8s VMs (x86-64-v2 requirement for ceph-csi)
- ArgoCD ingress: `server.insecure: true` + `backend-protocol: HTTP` — nginx terminates TLS using `wildcard-yanatech-tls` via `extraTls`, argocd-server runs plain HTTP internally. Do NOT use `ssl-passthrough` or `backend-protocol: HTTPS`
- Wildcard TLS secret must exist in each namespace — Reflector handles this automatically
- pfSense web UI must not use port 443 on `62.3.101.138` (conflicts with K8s ingress)
- Authentik requires PostgreSQL and Redis — both enabled via Helm values
- ArgoCD v3.4 does not support app-of-apps via directory source for Application resources — bootstrap.sh enumerates all apps explicitly grouped by sync-wave (0-7). Wave order matches dependency chain (metallb/ceph-csi → cilium/cert-manager/ingress → config → cluster-ops → platform → observability → foundational apps → all apps). ApplicationSet migration planned as a dedicated session.
- MetalLB IP pool name is `k8s-pool` (not `default-pool`)
- Vaultwarden database now lives on VM 110 (`192.168.22.40`, db `vaultwarden`), migrated off Authentik's bundled Postgres 2026-05-31. `DATABASE_URL` in `vaultwarden-secret` points there; role password is URL-safe hex (a base64 password breaks `postgresql://` parsing). Old DB dropped from Authentik's PG 2026-05-31 — final pre-drop dump retained on cp-1
- Vaultwarden Deployment must use `strategy: { type: Recreate }`. Its `/data` PVC is RWO on ceph-rbd, so the default RollingUpdate deadlocks on restart — the new pod can't mount the volume while the old pod holds it (Multi-Attach), leaving the rollout stuck. If it ever deadlocks, `scale --replicas=0` (wait for both pods gone) then `--replicas=1`
- Migrating a Postgres DB between the in-cluster Bitnami instance and VM 110: the Bitnami pod stores passwords in files (`$POSTGRES_PASSWORD_FILE`, `$POSTGRES_POSTGRES_PASSWORD_FILE`), not env values, and the `postgres` superuser password in the file can be stale vs the running DB — the `authentik` role (cluster owner) works. Dump/load via `PGPASSWORD` + discrete `PG*` env vars, never a `postgresql://` URL, to avoid special-char parsing failures
- Authentik DB connection lives entirely in the manual `authentik-secret` (`AUTHENTIK_POSTGRESQL__HOST/__NAME/__USER/__PASSWORD`); the chart sets `authentik.existingSecret` and does NOT put the host in values, so cutover = patch `__HOST` in the secret + restart `authentik-server`/`authentik-worker`. No git change needed for the repoint
- Authentik's ArgoCD app has `automated.selfHeal: true` — pause it (`argocd app set authentik --sync-policy none`) before scaling deployments to 0 for a migration, or self-heal scales them straight back. Re-enable with `--sync-policy automated --self-heal --auto-prune` after
- Loading an Authentik dump into a fresh DB needs a SUPERUSER (the dump has `CREATE EXTENSION` + materialized views a plain LOGIN role can't create, and `ON_ERROR_STOP` aborts the whole load on the first one). Temporarily `ALTER ROLE authentik SUPERUSER` on VM 110 for the load, then `NOSUPERUSER`
- Strimzi 1.0.0 only supports Kafka 4.x — do not use 3.x versions
- kube-prometheus-stack Helm release name is `kube-prometheus-stack` (set via releaseName in ArgoCD app)
- `bootstrap.sh` enumerates every ArgoCD Application explicitly grouped by sync-wave — a new app needs BOTH its `argocd-app-<name>.yaml` committed AND a matching `kubectl apply` line in the correct wave section of `bootstrap.sh`, or it won't deploy on a fresh cluster
- ArgoCD does NOT honor Helm's `crds.keep` / `helm.sh/resource-policy: keep` annotation when pruning — deleting a CRD-bearing Application (cert-manager, metallb, etc.) can cascade-delete its CRDs and all dependent resources. Don't delete those Applications directly; `crds.keep: true` only protects against `helm uninstall`
- cert-manager operator is ArgoCD-managed via the jetstack chart (was a manual `helm install` until migrated) — the `cert-manager` app must apply before `cert-manager-config` so CRDs exist before the ClusterIssuer; bootstrap.sh orders them correctly, and the config app self-heals if it races ahead
- ArgoCD can show a permanent `OutOfSync` (app still Healthy) when the kube-apiserver defaults a field the Helm chart doesn't template — e.g. `hostUsers: true` on Deployments (v1.32 user-namespace defaulting). It's cosmetic, not real drift; a sync won't fix it because the apiserver re-adds the field. Fix with an `ignoreDifferences` entry on that jsonPointer (see `infrastructure/headlamp/argocd-app-headlamp.yaml` → `/spec/template/spec/hostUsers` for the pattern)
- Cloud-init `users:` list must NOT include `- default` alongside an explicit `- name: ubuntu` — on Ubuntu cloud images the default user is already `ubuntu`, so the two definitions collide and `lock_passwd` / `chpasswd` / `ssh_pwauth` silently fail to apply, locking you out of the VM (no password, sometimes no key). Define `ubuntu` explicitly with no `- default` entry. Applies to every cloud-init snippet (`k8s-init.yaml`, `postgres-init.yaml`, etc.)
- Cloud-init `chpasswd: { list: ... }` is deprecated and silently no-ops on the cloud-init shipped with Ubuntu 24.04 — the password never gets set, so console/password login fails even though SSH-key login still works (this is why the k8s VMs always worked by key but not by password). Use the modern form: `chpasswd: { expire: false, users: [{name: ubuntu, password: ubuntu, type: text}] }`. User/password modules only run once per instance, so an already-booted VM needs a fresh clone to pick up a snippet change
- ArgoCD apps that pull a **remote Helm chart with inline `spec.source.helm.values`** (e.g. `monitoring`, `authentik`) render from the live Application CR, NOT from git — editing the `argocd-app-*.yaml` in git is a silent no-op until you `kubectl apply -f` the Application manifest (then ArgoCD re-renders + auto-syncs). Apps whose `source` is a git directory of plain manifests (e.g. `vaultwarden`) DO sync straight from git on push. Different mechanisms — don't assume a git push is enough
- Grafana OAuth via kube-prometheus-stack: the bundled grafana chart consumes env through `grafana.env` (map) + `grafana.envValueFrom` (map, for secretKeyRef) — `extraEnvVars` / `envFromSecrets` (Bitnami-style) are silently ignored. Authentik's `authorize`/`token`/`userinfo` endpoints are global (`https://auth.yanatech.co.uk/application/o/authorize/`); only discovery/jwks/`end-session` are slug-scoped (`/application/o/grafana/...`). Role mapping reads the `groups` claim (carried by the default `profile` scope): `contains(groups, 'authentik Admins') && 'Admin' || 'Viewer'`. Client ID/secret live in `grafana-authentik-secret` (keys `client_id`/`client_secret`)
- ArgoCD SSO via Authentik OIDC uses Dex (argocd-dex-server). Authentik app slug `argo-cd`; clientID in values (`infrastructure/argocd/argocd-app-argocd.yaml`), clientSecret in `argocd-secret` key `dex.authentik.clientSecret` (patched manually, not in git). Dex config: issuer `https://auth.yanatech.co.uk/application/o/argo-cd/`, scopes `openid profile email groups`, `insecureEnableGroups: true`. RBAC: `g, authentik Admins, role:admin` + `scopes: '[groups]'`. Redirect URIs in Authentik (strict, both required): `https://argocd.yanatech.co.uk/api/dex/callback` and `https://localhost:8085/auth/callback`
- argo-cd Helm chart 9.x ingress quirks (all three silent-ignore traps hit in practice): (1) `server.ingress.hosts` (list) is ignored — use `server.ingress.hostname` (singular string) for the primary rule host. (2) `server.ingress.tls` (list) is ignored — the chart interprets any non-false value as "enable TLS" and generates a TLS entry pointing at its default secret `argocd-server-tls` (which doesn't exist → nginx fake cert). Use `server.ingress.extraTls` (list of `{hosts, secretName}`) for a custom TLS secret. (3) `server.ingress.ingressClassName` must be set explicitly — it doesn't inherit from a cluster default. Pattern that works: `hostname: argocd.yanatech.co.uk` + `extraTls: [{hosts: [argocd.yanatech.co.uk], secretName: wildcard-yanatech-tls}]`; no `hosts:` or `tls:` list
- argo-cd ArgoCD Application must be an `argocd-app-argocd.yaml` wrapping the Helm chart with `valuesObject` — a standalone `values.yaml` cannot be `kubectl apply`'d directly (it has no `apiVersion`/`kind`). Use `valuesObject:` not `values: |` to avoid YAML indentation issues with multiline strings like `dex.config`
- pgAdmin4 OAuth2 via Authentik: the chart has no `config_local.py` support in Helm values — mount it via `extraConfigmapMounts` from a manually-created ConfigMap. Client ID/secret must be literal values in `config_local.py` (no env-var substitution). Three required keys beyond the basics: `OAUTH2_SERVER_METADATA_URL` (slug-scoped discovery endpoint, e.g. `/application/o/pgadmin/.well-known/openid-configuration`), `OAUTH2_API_BASE_URL` (must be slug-scoped, e.g. `/application/o/pgadmin/`, NOT root Authentik URL), and `OAUTH2_JWKS_URI` (`/application/o/pgadmin/jwks/`). Without `OAUTH2_SERVER_METADATA_URL` pgAdmin fails with `Missing "jwks_uri" in metadata`
- Headlamp SSO via Authentik is blocked by an upstream Headlamp bug (affects 0.42.0, latest as of 2026-06-02): `refreshing token: getting refresh token: key not found` — login succeeds but Headlamp immediately tries to refresh the token, finds no refresh token in its cache, and bounces back to the login page. Confirmed in pod logs. `offline_access` scope + PKCE (public client) does not resolve it — the refresh token is issued by Authentik but not stored by Headlamp. Workaround: running with service account token auth (`kubectl create token headlamp -n headlamp --duration=8760h`). Fix pending upstream (GitHub issues #3884, #4789, #4876, #5025). Revisit on 0.43.0+
- kube-prometheus-stack CRDs exceed the 262144-byte annotation limit on sync — fixed by adding `ServerSideApply=true` to the monitoring app's `syncOptions`. Required whenever the chart version is bumped
- Grafana env config in kube-prometheus-stack: `GF_AUTH_GENERIC_OAUTH_CLIENT_ID` and `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET` must both go in `grafana.envValueFrom` (not `grafana.env`) — putting either in `env` with a `valueFrom` block causes a Deployment validation error (`may not be specified when value is not empty`)
- Nextcloud chart (6.6.10) auto-installer silently fails if `config/` directory is not writable by `www-data` (uid 33) — fix with `extraInitContainers` running `chown -R 33:33 /var/www/html` on the `nextcloud-main` volume before startup. `trusted_domains` defaults to `localhost` only — must add the actual hostname via `occ config:system:set trusted_domains 1 --value=<host>` or via `configs.proxy.config.php`. `nginx.ingress.kubernetes.io/server-snippet` annotation is blocked by ingress-nginx by default — use plain annotations instead. The `installed: false` from `occ status` is misleading if `config.php` exists but `trusted_domains` is wrong; run `php occ maintenance:install` manually to confirm the real error
- Nextcloud bootstrap secret: generate passwords with `openssl rand -hex 16`; db-password must be set on pg1 first (`CREATE ROLE nextcloud WITH LOGIN PASSWORD '...'`), then referenced in the k8s secret
- Loki 6.x chart: `deploymentMode: SingleBinary` must be set explicitly, AND `backend.replicas: 0`, `read.replicas: 0`, `write.replicas: 0` must all be zeroed — otherwise the chart validator fires with "more than zero replicas configured for both single binary and simple scalable targets". The `negative structured metadata bytes received` errors in Loki logs are a cosmetic Promtail/Loki version skew issue — ingestion works correctly despite them
- ServiceMonitor resources must have label `release: kube-prometheus-stack` to be picked up by the Prometheus operator (confirmed via `kubectl get prometheus -n monitoring -o jsonpath='{.items[0].spec.serviceMonitorSelector}'`)
- Nextcloud OIDC SSO via `user_oidc` app: Nextcloud blocks outbound HTTP requests to RFC1918 addresses by default (`allow_local_address: false` in Guzzle) — `allow_local_remote_servers: true` must be set in config, otherwise the OIDC discovery URL fails with `Host "192.168.22.200" violates local access rules` when Authentik resolves to the MetalLB ingress VIP
- Gotify Alertmanager integration requires a bridge (`druggeri/alertmanager_gotify_bridge`) — Alertmanager's webhook payload is a JSON object with an `alerts` array, not Gotify's `{title, message, priority}` format. Pointing Alertmanager directly at `/message?token=...` returns `400: Field 'message' is required`
- argocd CLI `--grpc-web` warning: add `alias argocd='argocd --grpc-web'` to `~/.bashrc` to suppress it permanently. The `argocd config set-context` subcommand does not exist in this version
- Stakater Reloader: annotate deployments with `secret.reloader.stakater.com/reload: "<secret-name>"` to trigger rolling restarts on secret changes. `reloader.stakater.com/auto: "true"` triggers on any referenced secret/configmap change
- Immich chart (0.10.0+): postgresql subchart removed — omit `postgresql:` key entirely from values (setting `enabled: false` triggers a template error). DB connection via `DB_URL` env var under `server.controllers.main.containers.main.env`. Extensions `cube` and `earthdistance` require superuser — must be pre-created in the immich database before first start or migrations fail with `permission denied to create extension`
- Authentik forward auth pattern for nginx ingress: requires a **standalone outpost deployment** (not the embedded outpost) — the embedded outpost does not serve `/outpost.goauthentik.io/auth/nginx`. Create a new Proxy Provider (Forward auth, single application) + Application + dedicated Outpost (Local Kubernetes Cluster) in Authentik UI; Authentik auto-deploys the outpost pod and service (`ak-outpost-<name>`) in the `authentik` namespace. Then: (1) add `auth-url`, `auth-signin`, `auth-response-headers`, `auth-snippet` (with `proxy_set_header X-Original-URL`) annotations to the app ingress; (2) create an ExternalName Service in the app namespace pointing to the outpost; (3) create a second ingress routing `/outpost.goauthentik.io` to the outpost ExternalName service. `allowSnippetAnnotations: true` and `annotations-risk-level: Critical` must be set in ingress-nginx values
- ingress-nginx snippet annotations: `allowSnippetAnnotations: true` enables `nginx.ingress.kubernetes.io/auth-snippet` and `configuration-snippet`. `annotations-risk-level: Critical` is required when combining `auth-snippet` with `auth-url` — without it the admission webhook blocks the ingress with "risky annotation" error
- Cilium native routing mode: all k8s nodes on `192.168.22.0/24` flat L2 via `vmbr0` on Proxmox — no BGP integration needed, direct routing between nodes on same subnet. kube-proxy fully replaced by Cilium eBPF. Flannel `cni0`/`flannel.1` interfaces removed from all nodes during migration. Hubble relay connects to all 6 nodes on port 4244.
- When draining nodes during maintenance, Kafka and ingress-nginx PDBs will block eviction — delete them before draining: `kubectl delete pdb -n kafka kafka-cluster-kafka kafka-cluster-entity-operator` and `kubectl delete pdb -n ingress-nginx ingress-nginx-controller`. Strimzi and ArgoCD recreate them automatically after pods reschedule.
- After a CNI migration or node drain, pods with stale IPs (from previous CNI) will CrashLoopBackOff on liveness/readiness probes — fix with `kubectl rollout restart daemonset/<name>` to get fresh IPs. Kured was affected by this after the Flannel→Cilium migration.
- Harbor v2.15.1 secret key trap: the chart mounts `secretKey` (exact key name) from the secret as a file volume for the core encryption key — `existingSecretSecretKeyKey` in Helm values does NOT override this mount. The secret must contain BOTH `HARBOR_ADMIN_PASSWORD` (env var) AND `secretKey` (file mount) as separate keys with the same secret-key value. If harbor-core fails with `references non-existent secret key: secretKey`, the secret is missing the `secretKey` key.
- Harbor database initialises with `HARBOR_ADMIN_PASSWORD` from the secret on **first boot only** — if the secret was wrong/empty during first boot, the password is baked into the DB. Fix: scale all Harbor deployments to 0, delete the `database-data-harbor-database-0` PVC, scale back up to let it reinitialise with the correct secret.
- Harbor OIDC + admin fallback: once OIDC auth mode is enabled, the main login page redirects to Authentik. To log in as local `admin`, use the direct URL: `https://harbor.yanatech.co.uk/account/sign-in?redirect_url=/harbor/projects`
- Harbor `notary` is disabled (`notary.enabled: false`) — deprecated in v2.15+ and removed in future versions. Do not enable it.
- Actions Runner Controller (new ARC): use OCI registry `ghcr.io/actions/actions-runner-controller-charts` not the legacy HTTP repo `actions-runner-controller.github.io/actions-runner-controller`. The legacy summerwind ARC uses `RunnerDeployment` CRDs which no longer install correctly — use `gha-runner-scale-set-controller` + `gha-runner-scale-set` charts only.
- ARC with ArgoCD: OCI Helm charts show `Unknown` sync status permanently — this is a known ArgoCD limitation with OCI registries, not a real error. Apps are Healthy despite the Unknown sync status.
- ARC controller CRDs (`AutoscalingRunnerSet.actions.github.com` etc.) require `ServerSideApply=true` and `Replace=true` in ArgoCD syncOptions — without these the CRDs fail to install and the controller CrashLoopBackOffs with `no matches for kind "AutoscalingRunnerSet"`.
- ARC runner sets require `controllerServiceAccount.name: actions-runner-controller-gha-rs-controller` set explicitly in values — auto-discovery via label `app.kubernetes.io/part-of=gha-rs-controller` fails when installed via ArgoCD and causes `No gha-rs-controller deployment found` error during helm template rendering.
- CNPG `spec.postgresql.parameters.shared_preload_libraries` is blocked by the admission webhook (`Can't set fixed configuration parameter`) — use `spec.postgresql.shared_preload_libraries` (list field) instead.
- CNPG superuser secret is named `pg-main-app` (not `pg-main-superuser`) — contains the `app` user, not postgres superuser. Access postgres superuser via `kubectl exec -it -n cnpg-clusters pg-main-1 -- psql -U postgres`.
- CNPG + vchord 1.1.1 GLIBC issue: vchord 1.1.1 requires GLIBC_2.33 but the CNPG bootstrap-controller init container runs on Debian Bullseye (GLIBC 2.31). Neither the tensorchord/vchord-scratch approach nor tensorchord/vchord-postgres image resolves this — the init container itself is Bullseye-based. Fix requires either: (1) CNPG 1.29 Image Catalog feature, or (2) a vchord build targeting GLIBC 2.31, or (3) waiting for CNPG to ship a Bookworm-based bootstrap image.
- Nextcloud stores the DB host in `config.php` on the PVC in addition to env vars — patching the k8s secret and ArgoCD app values is insufficient. Must also `sed` the `dbhost` value in `/var/www/html/config/config.php` directly, then delete the pod to pick it up cleanly.
- CNPG Barman Cloud deprecation: native Barman Cloud backup support is deprecated in CNPG 1.29 and will be removed in 1.30. Plan to migrate to the Barman Cloud Plugin before upgrading to 1.30.
- Infisical standalone Helm chart bundles its own ingress-nginx which consumes a MetalLB IP — disable via `infisical.ingress.nginx.enabled: false` in values AND add `ignoreDifferences` for the nginx Deployment/Service/IngressClass/ClusterRole/ClusterRoleBinding in the ArgoCD Application. Without both, ArgoCD will recreate the bundled nginx on every sync.
- Infisical CLI: the `infisical-core` package is the server Omnibus package, NOT the CLI. Install the CLI from `https://artifacts-cli.infisical.com/setup.deb.sh`. The `folders` command is a subcommand of `secrets` (`infisical secrets folders create`). Folders must be created before secrets can be added to them via CLI.
- ESO ClusterSecretStore for Infisical must set `hostAPI: https://infisical.yanatech.co.uk/api` — defaults to cloud API (`app.infisical.com`) which will give 401. Use `external-secrets.io/v1` (not `v1beta1`) and `environmentSlug` field (not `envSlug`). Machine identity must be added to the project members in Infisical UI, not just the org.
- ESO `remoteRef.key` for Infisical uses full path including folder: `/folder/SECRET_NAME` (e.g. `/vaultwarden/DATABASE_URL`).
