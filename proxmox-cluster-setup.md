# Proxmox Cluster — Setup Guide

> **Cluster:** cluster01  
> **Nodes:** pve1 / pve2 / pve3  
> **Last updated:** 2026-06-23  
> **PVE version:** 9.2.3 — Debian 13 (trixie) — kernel 7.0.6-2-pve  

This document is a complete record of how this cluster is built. It is intended to allow full recreation from bare metal.

---

## Table of Contents

1. [Hardware](#1-hardware)
2. [OS Installation](#2-os-installation)
3. [APT Repositories](#3-apt-repositories)
4. [Cluster Formation](#4-cluster-formation)
5. [Network Configuration](#5-network-configuration)
6. [Corosync — Dual-Ring HA](#6-corosync--dual-ring-ha)
7. [Ceph Storage](#7-ceph-storage)
8. [Proxmox Storage Configuration](#8-proxmox-storage-configuration)
9. [VM Template & Cloud-Init](#9-vm-template--cloud-init)
10. [Kubernetes VMs](#10-kubernetes-vms)
11. [High Availability](#11-high-availability)
12. [Backups](#12-backups)
13. [Firewall](#13-firewall)
14. [Notifications](#14-notifications)
15. [Maintenance Reference](#15-maintenance-reference)

---

## 1. Hardware

All three nodes are identical (Micro Computer (HK) Tech Limited Venus Series mini-PC).

### Per-Node Specs

| Component | Detail |
|---|---|
| CPU | Intel Core i5-12600H — 12 cores / 16 threads / 4.5 GHz boost |
| RAM | 64 GiB DDR5 |
| NIC (cluster) | Intel X710 10GbE SFP+ — dual port (`enp2s0f0np0`, `enp2s0f1np1`) |
| NIC (public) | Intel I226-V 2.5GbE (`enp87s0`) |
| NIC (secondary) | Intel I226-LM 2.5GbE (`enp90s0`) |
| WiFi | MediaTek MT7922 — unused, leave `DOWN` |
| NVMe (OS) | Crucial CT500P3PSSD8 — 465.8 GB |
| NVMe (OSD large) | Lexar NM790 — 2 TB |
| NVMe (OSD small) | Lexar NM790 — 1 TB |

### Node Addressing

| Node | Mgmt IP | OSPF Loopback | PCI NVMe slots |
|---|---|---|---|
| pve1 | 192.168.22.11 | 10.255.255.1 | nvme0 (2TB OSD), nvme1 (OS), nvme2 (1TB OSD) |
| pve2 | 192.168.22.12 | 10.255.255.2 | same slot order |
| pve3 | 192.168.22.13 | 10.255.255.3 | same slot order |

### Ceph OSD Assignment

| OSD | Node | Device | Size |
|---|---|---|---|
| osd.0 | pve1 | nvme0n1 (Lexar 2TB) | 1.86 TiB |
| osd.1 | pve2 | nvme0n1 (Lexar 2TB) | 1.86 TiB |
| osd.2 | pve3 | nvme0n1 (Lexar 2TB) | 1.86 TiB |
| osd.3 | pve1 | nvme2n1 (Lexar 1TB) | 0.93 TiB |
| osd.4 | pve2 | nvme2n1 (Lexar 1TB) | 0.93 TiB |
| osd.5 | pve3 | nvme2n1 (Lexar 1TB) | 0.93 TiB |

Total raw: **8.4 TiB** across 6 SSDs with replication factor 3.

---

## 2. OS Installation

Install Proxmox VE 9 from the official ISO onto `nvme1n1` (Crucial OS disk) on each node. Use the graphical installer.

**Installer settings:**
- Target disk: select the Crucial 465 GB NVMe (do **not** select the Lexar drives — those are reserved for Ceph)
- Filesystem: `ext4` (or `xfs`) — do **not** use ZFS for the OS disk; the Ceph OSD drives are bare block devices
- Hostname: `pve1.akan.home`, `pve2.akan.home`, `pve3.akan.home`
- Management IP: `192.168.22.11/24`, `192.168.22.12/24`, `192.168.22.13/24`
- Gateway: `192.168.22.1`
- DNS: `192.168.22.1`

After installation, verify the correct disk was used:

```bash
lsblk -d -o NAME,SIZE,MODEL
# nvme1n1 should be the Crucial (465.8G) and show as /
```

---

## 3. APT Repositories

No Proxmox subscription is used. Configure the no-subscription repositories on every node.

### `/etc/apt/sources.list.d/proxmox.sources`

```
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
```

### `/etc/apt/sources.list.d/ceph.sources`

```
Types: deb
URIs: http://download.proxmox.com/debian/ceph-squid
Suites: trixie
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
```

### `/etc/apt/sources.list.d/pve-enterprise.sources`

Comment out the enterprise repo (requires subscription):

```
# Types: deb
# URIs: https://enterprise.proxmox.com/debian/pve
# Suites: trixie
# Components: pve-enterprise
# Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
```

### `/etc/apt/sources.list.d/debian.sources`

```
Types: deb
URIs: http://deb.debian.org/debian/
Suites: trixie trixie-updates
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security/
Suites: trixie-security
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
```

After setting repositories:

```bash
apt update && apt full-upgrade -y
```

---

## 4. Cluster Formation

Run on **pve1 only** to create the cluster:

```bash
pvecm create cluster01 --link0 192.168.22.11 --link1 10.10.20.1
```

Then on **pve2**:

```bash
pvecm add 192.168.22.11 --link0 192.168.22.12 --link1 10.10.10.2
```

Then on **pve3**:

```bash
pvecm add 192.168.22.11 --link0 192.168.22.13 --link1 10.10.30.2
```

Verify from any node:

```bash
pvecm status   # all 3 nodes, Quorate: Yes
pvecm nodes
```

---

## 5. Network Configuration

Each node has the same physical NIC layout but different addresses. The design uses:

- **vmbr0** — VM/management bridge on the 2.5GbE I226-V NIC, VLAN-aware
- **vmbr1** — secondary VM bridge on the 2.5GbE I226-LM NIC, VLAN-aware
- **enp2s0f0np0 / enp2s0f1np1** — Intel X710 10GbE SFP+ dual-port, dedicated to Ceph cluster replication and Corosync ring1, MTU 9000

The three nodes form a **full mesh** of point-to-point `/30` links on the X710 ports. OSPF (FRR) distributes reachability across the mesh.

### Point-to-Point Link Topology

```
pve1 enp2s0f0np0 (10.10.10.1/30) ←→ pve2 enp2s0f0np0 (10.10.10.2/30)
pve1 enp2s0f1np1 (10.10.20.1/30) ←→ pve3 enp2s0f0np0 (10.10.20.2/30)
pve2 enp2s0f1np1 (10.10.30.1/30) ←→ pve3 enp2s0f1np1 (10.10.30.2/30)
```

Every pair of nodes has a direct 10GbE link. All Ceph replication and Corosync ring1 traffic flows over this dedicated network.

### `/etc/network/interfaces` — pve1

```
auto lo
iface lo inet loopback

auto lo:ospf
iface lo:ospf inet static
    address 10.255.255.1/32

iface enp87s0 inet manual
iface enp90s0 inet manual

auto enp2s0f0np0
iface enp2s0f0np0 inet static
    address 10.10.10.1/30
    mtu 9000

auto enp2s0f1np1
iface enp2s0f1np1 inet static
    address 10.10.20.1/30
    mtu 9000

auto vmbr0
iface vmbr0 inet static
    address 192.168.22.11/24
    gateway 192.168.22.1
    bridge-ports enp87s0
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 22 111

auto vmbr1
iface vmbr1 inet static
    address 192.168.33.11/24
    bridge-ports enp90s0
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 33
```

### `/etc/network/interfaces` — pve2

Same structure, different addresses:

```
lo:ospf   10.255.255.2/32
enp2s0f0np0  10.10.10.2/30   # link to pve1
enp2s0f1np1  10.10.30.1/30   # link to pve3
vmbr0     192.168.22.12/24
vmbr1     192.168.33.12/24
```

### `/etc/network/interfaces` — pve3

```
lo:ospf   10.255.255.3/32
enp2s0f0np0  10.10.20.2/30   # link to pve1
enp2s0f1np1  10.10.30.2/30   # link to pve2
vmbr0     192.168.22.13/24
vmbr1     192.168.33.13/24
```

### OSPF via FRR

Install FRR on every node:

```bash
apt install frr
```

Enable the OSPF daemon in `/etc/frr/daemons`:

```
ospfd=yes
```

#### `/etc/frr/frr.conf` — pve1

```
frr version 10.3.1
frr defaults traditional
hostname pve1
log syslog informational
no ipv6 forwarding
service integrated-vtysh-config

interface enp2s0f0np0
 ip ospf network point-to-point
 no ip ospf passive
exit

interface enp2s0f1np1
 ip ospf network point-to-point
 no ip ospf passive
exit

router ospf
 ospf router-id 10.255.255.1
 timers throttle spf 10 100 500
 passive-interface default
 network 10.10.10.0/30 area 0
 network 10.10.20.0/30 area 0
 network 10.255.255.1/32 area 0
exit
```

#### `/etc/frr/frr.conf` — pve2

```
hostname pve2
router ospf
 ospf router-id 10.255.255.2
 passive-interface default
 network 10.10.10.0/30 area 0
 network 10.10.30.0/30 area 0
 network 10.255.255.2/32 area 0
```

#### `/etc/frr/frr.conf` — pve3

```
hostname pve3
router ospf
 ospf router-id 10.255.255.3
 passive-interface default
 network 10.10.20.0/30 area 0
 network 10.10.30.0/30 area 0
 network 10.255.255.3/32 area 0
```

`passive-interface default` prevents OSPF from sending hellos on vmbr0/vmbr1/lo. Only the two X710 ports form OSPF adjacencies.

Enable and start FRR:

```bash
systemctl enable --now frr
```

Verify adjacencies from any node:

```bash
vtysh -c "show ip ospf neighbor"   # should show 2 neighbors
vtysh -c "show ip route ospf"      # should show routes to other nodes
```

### ECMP Asymmetric Routing Fix (pve2 and pve3 only)

**Problem:** OSPF advertises two equal-cost paths between pve2 and pve3 — one via the direct pve2↔pve3 link (10.10.30.0/30) and one via pve1. When ECMP hashes a TCP connection onto the direct link, pve2 uses source IP `10.10.30.1` (not its Ceph cluster IP `10.10.10.2`) to reach pve3. pve3 responds via pve1 (source `10.10.20.2`), and pve2's socket expects a reply from `10.10.20.2` — not from `10.10.30.1`. This asymmetry breaks the TCP three-way handshake, leaving sockets in SYN-RECV/FIN-WAIT-1 and causing Ceph OSD heartbeat failures between pve2 and pve3 OSDs.

**Fix:** Add a static route (metric 0, beats OSPF metric 20) that forces cross-cluster traffic through pve1 on both affected nodes, and a source-based policy routing rule as defence-in-depth. Both are applied at boot via a systemd oneshot service.

Create `/usr/local/sbin/ceph-routing-setup.sh` on **pve2**:

```bash
#!/bin/bash
# Fix ECMP asymmetric routing: force pve3 cluster traffic via pve1 (symmetric path)
ip route replace 10.10.20.0/30 via 10.10.10.1 dev enp2s0f0np0
ip route replace 10.10.0.0/16 via 10.10.10.1 dev enp2s0f0np0 table 200
ip rule del from 10.10.10.2 table 200 2>/dev/null; ip rule add from 10.10.10.2 table 200 priority 100
```

Create `/usr/local/sbin/ceph-routing-setup.sh` on **pve3**:

```bash
#!/bin/bash
# Fix ECMP asymmetric routing: force pve2 cluster traffic via pve1 (symmetric path)
ip route replace 10.10.10.0/30 via 10.10.20.1 dev enp2s0f0np0
ip route replace 10.10.0.0/16 via 10.10.20.1 dev enp2s0f0np0 table 200
ip rule del from 10.10.20.2 table 200 2>/dev/null; ip rule add from 10.10.20.2 table 200 priority 100
```

Create `/etc/systemd/system/ceph-routing.service` on **both pve2 and pve3**:

```ini
[Unit]
Description=Ceph OSD ECMP Routing Fix
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/ceph-routing-setup.sh

[Install]
WantedBy=multi-user.target
```

Enable on both nodes:

```bash
chmod 755 /usr/local/sbin/ceph-routing-setup.sh
systemctl daemon-reload
systemctl enable --now ceph-routing.service
```

**pve1 does not need this fix** — its two X710 ports have direct kernel-connected routes to both pve2 (`10.10.10.0/30 dev enp2s0f0np0`) and pve3 (`10.10.20.0/30 dev enp2s0f1np1`), so no ECMP ambiguity exists.

**Why the static route survives FRR restarts:** `ip route replace` installs a `proto boot` route with metric 0. FRR's OSPF routes use `proto ospf` with metric 20. Both coexist in the kernel RIB; the kernel always selects the lower metric. FRR cannot replace the static route.

---

### DNS

Each node uses the home router as primary DNS with Cloudflare as fallback:

```bash
pvesh set /nodes/pve1/dns --dns1 192.168.22.1 --dns2 1.1.1.1 --search akan.home
pvesh set /nodes/pve2/dns --dns1 192.168.22.1 --dns2 1.1.1.1 --search akan.home
pvesh set /nodes/pve3/dns --dns1 192.168.22.1 --dns2 1.1.1.1 --search akan.home
```

---

## 6. Corosync — Dual-Ring HA

Corosync uses **knet transport** with two rings:

| Ring | Interface | Network | Priority | Role |
|---|---|---|---|---|
| ring0 | vmbr0 (192.168.22.x) | Public/management | 1 (low) | Failover only |
| ring1 | X710 cluster links (10.10.x.x) | Dedicated cluster | 2 (high) | Primary path |

Ring1 (the dedicated 10GbE mesh) carries all corosync heartbeat traffic. If it fails, ring0 on the management network provides quorum continuity. `link_mode: passive` keeps one ring active at a time.

### `/etc/pve/corosync.conf`

```
logging {
  debug: off
  to_syslog: yes
}

nodelist {
  node {
    name: pve1
    nodeid: 1
    quorum_votes: 1
    ring0_addr: 192.168.22.11
    ring1_addr: 10.10.20.1
  }
  node {
    name: pve2
    nodeid: 2
    quorum_votes: 1
    ring0_addr: 192.168.22.12
    ring1_addr: 10.10.10.2
  }
  node {
    name: pve3
    nodeid: 3
    quorum_votes: 1
    ring0_addr: 192.168.22.13
    ring1_addr: 10.10.30.2
  }
}

quorum {
  provider: corosync_votequorum
}

totem {
  cluster_name: cluster01
  config_version: 6
  interface {
    linknumber: 0
    knet_link_priority: 1
  }
  interface {
    linknumber: 1
    knet_link_priority: 2
  }
  ip_version: ipv4-6
  link_mode: passive
  secauth: on
  version: 2
}
```

**Note on ring1 addresses:** Each node's `ring1_addr` is its end of a direct point-to-point X710 link. OSPF ensures the addresses are routable across the mesh:
- pve1's ring1 (10.10.20.1) is directly connected to pve3 and OSPF-reachable from pve2
- pve2's ring1 (10.10.10.2) is directly connected to pve1
- pve3's ring1 (10.10.30.2) is directly connected to pve2

To apply a corosync config change, edit `/etc/pve/corosync.conf` (pmxcfs syncs it cluster-wide), increment `config_version`, then reload on all nodes:

```bash
# Run on each node:
corosync-cfgtool -R
```

Verify:

```bash
pvecm status   # Ring ID should stabilise, Quorate: Yes
```

---

## 7. Ceph Storage

Ceph 19.2.3 (Squid) runs natively on Proxmox. All daemons (mon, mgr, mds, osd) are managed by PVE.

> **Pending upgrade**: Ceph 19.2.4 was released upstream 2026-06-01 and fixes known RocksDB crash bugs affecting mon and OSD daemons on this cluster. The Proxmox `ceph-squid` repo had not packaged it as of 2026-06-23. Check periodically: `apt-get update && apt-cache policy ceph-mon | grep Candidate`. When `19.2.4-pve*` appears, do a rolling upgrade: pve3 → pve2 → pve1 (upgrade the current mon leader last).

### Architecture

```
Cluster network: 10.10.0.0/16   (X710 mesh — OSD replication, heartbeats)
Public network:  192.168.22.0/24 (clients — Kubernetes CSI, PVE UI)

Monitors:  pve1, pve2, pve3  (port 3300 v2 / 6789 v1)
Managers:  pve2 (active), pve3 (standby), pve1 (standby)
MDS:       1 active (round-robin), 2 standby
OSDs:      6 (2 per node, all NVMe SSD)
```

### `/etc/ceph/ceph.conf`

```ini
[global]
    auth_client_required  = cephx
    auth_cluster_required = cephx
    auth_service_required = cephx

    public_network  = 192.168.22.0/24
    cluster_network = 10.10.0.0/16
    ms_bind_ipv4 = true
    ms_bind_ipv6 = false
    ms_bind_port_min = 6800
    ms_bind_port_max = 7100

    fsid     = 92197a62-7cf9-49eb-a0cb-5e0b9bbff52a
    mon_host = 192.168.22.11,192.168.22.12,192.168.22.13
    mon_allow_pool_delete = true

    osd_pool_default_size    = 3
    osd_pool_default_min_size = 2
    osd_pool_default_pg_num  = 64
    osd_pool_default_pgp_num = 64

    osd_max_backfills        = 2
    osd_recovery_max_active  = 4
    osd_recovery_op_priority = 2
    osd_client_op_priority   = 32
    osd_recovery_sleep       = 0.1

    bluestore_cache_autotune     = true
    osd_memory_target            = 3G
    bluestore_cache_kv_ratio     = 0.3
    bluestore_cache_meta_ratio   = 0.2
    osd_op_queue                 = wpq
    osd_op_queue_cut_off         = high
    osd_max_write_size           = 128
    osd_op_num_threads_per_shard = 2

    osd_scrub_begin_hour   = 1
    osd_scrub_end_hour     = 7
    osd_scrub_sleep        = 0.1
    osd_scrub_chunk_max    = 5
    osd_deep_scrub_stride  = 1048576
    osd_scrub_auto_repair  = true

    log_to_stderr      = false
    log_to_syslog      = true
    log_to_syslog_level = warning
    log_file           = /var/log/ceph/ceph.log

[client]
    keyring = /etc/pve/priv/$cluster.$name.keyring

[client.crash]
    keyring = /etc/pve/ceph/$cluster.$name.keyring

[mon]
    mon_memory_target    = 1073741824
    mon_osd_cache_size   = 64

[mon.pve1]
    public_addr = 192.168.22.11

[mon.pve2]
    public_addr = 192.168.22.12

[mon.pve3]
    public_addr = 192.168.22.13

[mds]
    keyring = /var/lib/ceph/mds/ceph-$id/keyring

[mds.pve1]
    host = pve1
    mds_standby_for_name = pve

[mds.pve2]
    host = pve2
    mds_standby_for_name = pve

[mds.pve3]
    host = pve3
    mds_standby_for_name = pve

[mgr]
    mgr_stats_period = 5
    mgr_tick_period  = 5

[osd]
    osd_heartbeat_grace          = 120
    osd_heartbeat_interval       = 6
    osd_mon_heartbeat_interval   = 30
    bluestore_min_alloc_size_hdd = 64K
    bluestore_min_alloc_size_ssd = 4K
```

### Initialising Ceph via PVE

Use the PVE web UI or `pveceph` CLI. On **pve1**:

```bash
# Initialise Ceph cluster (auto-creates /etc/ceph/ceph.conf)
pveceph init --network 192.168.22.0/24 --cluster-network 10.10.0.0/16

# Create monitors
pveceph mon create    # on pve1
ssh pve2 pveceph mon create
ssh pve3 pveceph mon create

# Create managers
pveceph mgr create    # on pve1
ssh pve2 pveceph mgr create
ssh pve3 pveceph mgr create

# Create OSDs (repeat on each node for both Lexar drives)
# On pve1:
pveceph osd create /dev/nvme0n1   # 2TB Lexar
pveceph osd create /dev/nvme2n1   # 1TB Lexar

# On pve2 and pve3: same commands via SSH
```

### Pools

After OSD creation, create pools:

```bash
# RBD pool — VM disks (Proxmox VMs)
pveceph pool create rbd --size 3 --min-size 2 --pg-autoscale-mode on

# Kubernetes pool — K8s PVC data (created by ceph-csi in Kubernetes)
ceph osd pool create kubernetes 32
ceph osd pool application enable kubernetes rbd
rbd pool init kubernetes

# CephFS — backups, ISOs, snippets
pveceph fs create --pg-num 32 --add-storage
```

### Kubernetes CRUSH Rule

The `kubernetes` pool uses a dedicated CRUSH rule (`kubernetes_rule`) backed by the `kubernetes_safe` CRUSH root. Normally all three hosts are members, giving full 3-replica coverage. During pve3 maintenance or recovery, pve3 can be unlinked to restrict placement to pve1+pve2 only — allowing the pool to degrade gracefully to 2 replicas without peering failures.

**Current state:** pve1, pve2, and pve3 are all in `kubernetes_safe`. All 6 OSDs are up at full reweight and primary-affinity 1.0 (restored 2026-06-23 after ECMP routing fix and gradual reweight: 0.05 → 0.1 → 0.25 → 0.5 → 1.0).

The `kubernetes_safe` root bucket references the same host buckets as the `default` root (Ceph supports shared subtrees):

```bash
# Initial setup (one-time)
ceph osd crush add-bucket kubernetes_safe root
ceph osd crush link pve1 root=kubernetes_safe
ceph osd crush link pve2 root=kubernetes_safe
ceph osd crush link pve3 root=kubernetes_safe
ceph osd crush rule create-replicated kubernetes_rule kubernetes_safe host
ceph osd pool set kubernetes crush_rule kubernetes_rule

# During pve3 maintenance — restrict to pve1+pve2 only:
ceph osd crush unlink pve3 root=kubernetes_safe

# After pve3 returns — restore full 3-node placement:
ceph osd crush link pve3 root=kubernetes_safe
```

To verify current placement:

```bash
ceph osd crush dump | python3 -c "
import json,sys; d=json.load(sys.stdin)
for b in d['buckets']:
    if 'kubernetes' in b.get('name',''):
        print(b['name'], 'items:', [i['id'] for i in b['items']])
"
ceph osd pool get kubernetes crush_rule
```

### Pool Protection

Production pools have deletion and PG-change protection:

```bash
ceph osd pool set rbd nodelete true
ceph osd pool set rbd nopgchange true
ceph osd pool set kubernetes nodelete true
ceph osd pool set kubernetes nopgchange true
```

### Pool Compression

```bash
# kubernetes pool — snappy (Postgres WAL, JSON, MongoDB data)
ceph osd pool set kubernetes compression_mode aggressive
ceph osd pool set kubernetes compression_algorithm snappy
ceph osd pool set kubernetes compression_min_blob_size 8192

# cephfs_data pool — zstd (backups, ISOs)
ceph osd pool set cephfs_data compression_mode aggressive
ceph osd pool set cephfs_data compression_algorithm zstd
```

### Ceph Tuning (runtime config)

Applied via `ceph config set`, persisted in the monitor config database:

```bash
# Faster OSD failover (default 600s)
ceph config set global mon_osd_down_out_interval 300

# Slow ping warning
ceph config set mon mon_warn_on_slow_ping_time 250

# Mon election: classic (rank-based)
# NOTE: connectivity strategy was trialled but caused mon crashes on pve1 and pve3 —
# it persists connectivity scores to the mon RocksDB on every ping, which triggered
# MonitorDBStore::apply_transaction aborts under load (Ceph 19.2.3 bug).
# Revert to classic once 19.2.4 is available and the underlying bug is fixed.
ceph mon set election_strategy classic
```

### MGR Modules

Enabled: `balancer`, `dashboard`, `iostat`, `pg_autoscaler`, `prometheus`, `restful`, `telemetry` (all on).

Disabled:

```bash
ceph mgr module disable nfs   # not in use
```

### MDS

Three MDS daemons run (one per node) with one active and two standby. CephFS is used only for Proxmox backup and ISO storage — a single active MDS is sufficient.

---

## 8. Proxmox Storage Configuration

### `/etc/pve/storage.cfg`

```
dir: local
    path /var/lib/vz
    content iso,images,import,backup,vztmpl

lvmthin: local-lvm
    thinpool data
    vgname pve
    content images,rootdir

rbd: rbd
    content images,rootdir
    krbd 0
    pool rbd

cephfs: cephfs
    path /mnt/pve/cephfs
    content import,snippets,iso,vztmpl,backup
    fs-name cephfs
    prune-backups keep-all=1

dir: snippets
    path /var/lib/vz/snippets
    content snippets
```

**Primary VM storage** is `rbd` (Ceph RBD). The `local-lvm` thin pool is used only for cloud-init CDROMs. `cephfs` is used for backups, ISOs, and the cloud-init snippet.

---

## 9. VM Template & Cloud-Init

All Kubernetes VMs are provisioned from a single Ubuntu 24.04 cloud-image template with a shared cloud-init snippet.

### Create the Template

```bash
# Download Ubuntu 24.04 cloud image
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img \
  -O /var/lib/vz/template/iso/ubuntu-24.04-cloud.img

# Create template VM (VMID 9000)
qm create 9000 \
  --name ubuntu-2404-template \
  --memory 2048 \
  --cores 2 \
  --cpu host \
  --machine q35 \
  --bios ovmf \
  --efidisk0 local-lvm:0,efitype=4m,pre-enrolled-keys=0 \
  --scsihw virtio-scsi-single \
  --scsi0 local-lvm:0,import-from=/var/lib/vz/template/iso/ubuntu-24.04-cloud.img,cache=none,discard=on,ssd=1 \
  --ide2 local-lvm:cloudinit,media=cdrom \
  --serial0 socket \
  --vga serial0 \
  --net0 virtio,bridge=vmbr0 \
  --agent enabled=1 \
  --ostype l26

# Convert to template
qm template 9000
```

### Cloud-Init Snippet

Stored at `/var/lib/vz/snippets/k8s-init.yaml` and referenced by all K8s VMs:

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
      - ssh-rsa <pve1-root-key>
      - ssh-rsa <pve2-root-key>
      - ssh-rsa <pve3-root-key>
      - ssh-rsa <workstation-key>

chpasswd:
  list: |
    ubuntu:ubuntu
  expire: false
ssh_pwauth: true

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

The `runcmd` section disables swap, loads the required kernel modules, and applies the sysctl settings required by Kubernetes — all before the first boot is complete.

---

## 10. Kubernetes VMs

Six VMs across three nodes. Control-plane VMs have 4 cores / 8 GB; workers have 8 cores / 40 GB.

### VM Inventory

| VMID | Name | Node | Cores | RAM | Disk | IP |
|---|---|---|---|---|---|---|
| 101 | k8s-cp-1 | pve1 | 4 | 8 GB | 50 GB rbd | 192.168.22.21 |
| 102 | k8s-cp-2 | pve2 | 4 | 8 GB | 50 GB rbd | 192.168.22.22 |
| 103 | k8s-cp-3 | pve3 | 4 | 8 GB | 50 GB rbd | 192.168.22.23 |
| 201 | k8s-worker-1 | pve1 | 8 | 40 GB | 100 GB rbd | 192.168.22.31 |
| 202 | k8s-worker-2 | pve2 | 8 | 40 GB | 100 GB rbd | 192.168.22.32 |
| 203 | k8s-worker-3 | pve3 | 8 | 40 GB | 100 GB rbd | 192.168.22.33 |

### Cloning from Template

```bash
# Example: create k8s-cp-1 (VMID 101) on pve1
qm clone 9000 101 \
  --name k8s-cp-1 \
  --full \
  --storage rbd \
  --target pve1

# Resize disk
qm disk resize 101 scsi0 50G

# Set cloud-init
qm set 101 \
  --cicustom "user=local:snippets/k8s-init.yaml" \
  --ciuser ubuntu \
  --ipconfig0 "ip=192.168.22.21/24,gw=192.168.22.1" \
  --nameserver 192.168.22.1 \
  --onboot 1 \
  --tags "control-plane,k8s"

# Start
qm start 101
```

Repeat for each VM, adjusting VMID, name, IP, disk size, and target node. Workers:

```bash
qm clone 9000 201 --name k8s-worker-1 --full --storage rbd --target pve1
qm disk resize 201 scsi0 100G
qm set 201 \
  --cores 8 --memory 40960 \
  --cicustom "user=local:snippets/k8s-init.yaml" \
  --ciuser ubuntu \
  --ipconfig0 "ip=192.168.22.31/24,gw=192.168.22.1" \
  --nameserver 192.168.22.1 \
  --onboot 1 \
  --tags "k8s,worker"
qm start 201
```

### Common VM Config (all VMs)

| Setting | Value | Reason |
|---|---|---|
| `bios` | `ovmf` | UEFI — required for Secure Boot capable guests |
| `machine` | `q35` | Modern PCIe chipset, required for OVMF |
| `cpu` | `host` | Pass through host CPU flags — needed for AVX/AES in containers |
| `scsihw` | `virtio-scsi-single` | Best performance for single-queue NVMe-backed RBD |
| `cache` | `none` | Let Ceph handle caching; guest-side cache adds no benefit |
| `discard` | `on` | Propagate TRIM to Ceph RBD thin provisioning |
| `ssd` | `1` | Hint guest that disk is SSD; enables rotational=0 in guest |
| `serial0` | `socket` | Console access without VNC; required with `vga serial0` |
| `agent` | `enabled=1` | QEMU guest agent for clean shutdown, IP reporting |
| `onboot` | `1` | Auto-start on PVE node boot (HA also handles this) |

---

## 11. High Availability

All K8s VMs and LXC containers are enrolled in Proxmox HA. HA provides automatic live migration on node failure.

### HA Resources

| SID | Current Node | max_restart | max_relocate |
|---|---|---|---|
| vm:101 | pve1 | 3 | 2 |
| vm:102 | pve2 | 3 | 2 |
| vm:103 | pve3 | 3 | 2 |
| vm:201 | pve1 | 3 | 2 |
| vm:202 | pve2 | 3 | 2 |
| vm:203 | pve3 | 3 | 2 |
| ct:401 | pve2 | 3 | 1 |
| ct:113 | pve3 | — | — |

### HA Node Affinity Rules

Affinity rules guide VM placement preferences without hard restrictions (`strict: false`):

```bash
# Control-plane VMs prefer pve2 and pve3; pve1 is last resort
pvesh create /cluster/ha/rules \
  --rule k8s-cp-affinity \
  --type node-affinity \
  --resources "vm:101,vm:102,vm:103" \
  --nodes "pve2:2,pve3:2,pve1:1" \
  --strict 0

# Worker VMs are balanced equally across all nodes
pvesh create /cluster/ha/rules \
  --rule k8s-worker-affinity \
  --type node-affinity \
  --resources "vm:201,vm:202,vm:203" \
  --nodes "pve1:2,pve2:2,pve3:2" \
  --strict 0
```

Rationale for lower pve1 CP priority: pve1 has experienced recurring Ceph daemon crashes (mon.pve1 and osd.0/osd.3). K8s control-plane nodes are more sensitive to instability than workers, since losing a CP node triggers etcd re-election. Root cause identified 2026-06-23: Ceph 19.2.3 bugs in MonitorDBStore and BlueStore RocksDB — see Mon Leader Management section. Mitigated by switching to classic election strategy; full fix requires upgrade to 19.2.4+.

### Enrolment Commands

```bash
# Add a VM to HA
ha-manager add vm:<vmid> --max_restart 3 --max_relocate 2 --state started

# Verify
ha-manager status
```

### Fencing

Fencing is armed by default (`CRM watchdog active` in `ha-manager status`). The watchdog will reboot a non-responsive node to guarantee resource exclusivity before migration. Do not disable fencing.

---

## 12. Backups

### Schedule

| Job ID | VMs / CTs | Schedule | Storage | Mode | Retention |
|---|---|---|---|---|---|
| `k8s-vms-weekly` | 101,102,103,201,202,203,401 | Sunday 03:00 | cephfs | snapshot | 4 weekly, 2 monthly |

Velero (in Kubernetes) runs at Sunday 02:00. Proxmox vzdump at 03:00 captures the full VM disk after Velero has completed its cluster-level backup.

### Creating the Backup Job

```bash
pvesh create /cluster/backup \
  --id k8s-vms-weekly \
  --storage cephfs \
  --schedule "sun 03:00" \
  --compress zstd \
  --mode snapshot \
  --vmid 101,102,103,201,202,203,401 \
  --notes-template "{{guestname}} - {{node}}" \
  --prune-backups "keep-weekly=4,keep-monthly=2" \
  --comment "Weekly backup of all K8s VMs and homepage"
```

**Mode `snapshot`** uses a temporary RBD snapshot to produce a consistent backup without suspending the VM. The backup stream goes directly to CephFS — no intermediate node storage required.

Backups land in `/mnt/pve/cephfs/dump/` and are visible in the PVE UI under each node's Backup tab.

---

## 13. Firewall

The PVE node firewall is enabled on all three nodes. Rules allow management access from the cluster LAN (192.168.22.0/24) and the laptop network (192.168.11.0/24); all other inbound traffic is dropped.

### Rule Set (per node)

| Proto | Port | Source | Purpose |
|---|---|---|---|
| TCP | 22 | 192.168.22.0/24, 192.168.11.0/24 | SSH |
| TCP | 8006 | 192.168.22.0/24, 192.168.11.0/24 | PVE web UI |
| ICMP | — | 192.168.22.0/24, 192.168.11.0/24 | Ping |
| UDP | 5404:5412 | 192.168.22.0/24 | Corosync ring0 |
| UDP | 5404:5412 | 10.10.0.0/16 | Corosync ring1 |
| any | any | 10.10.0.0/16 | Ceph cluster network |
| TCP | 3300 | 192.168.22.0/24 | Ceph mon v2 |
| TCP | 6789 | 192.168.22.0/24 | Ceph mon v1 |
| TCP | 6800:7300 | 192.168.22.0/24 | Ceph OSD |

The cluster firewall is **not** enabled at the datacenter level (which would filter inter-VM traffic) — only node-level firewalls are active.

For the exact CLI commands to recreate rules on a replacement node, see `pve-node-operations.md` §2.10 (restore) and §3.8 (new node).

### Verify

```bash
# List rules on a node
pvesh get /nodes/pve1/firewall/rules

# Check firewall is enabled
pvesh get /nodes/pve1/firewall/options | grep enable

# Check active iptables rules
iptables -L PVEFW-HOST-IN -n --line-numbers
```

### TLS for PVE Web UI

Handled via HAProxy reverse proxy — not using the built-in `pvenode acme` method. The Cloudflare DNS-01 + Let's Encrypt cert is terminated at HAProxy; PVE web UI behind it uses its self-signed cert on the internal side.

---

## 14. Notifications

All Proxmox alerts (backup results, HA events, task failures) route to both local mail and Gotify.

### Gotify Endpoint

```bash
pvesh create /cluster/notifications/endpoints/gotify \
  --name gotify \
  --server "https://gotify.yanatech.co.uk" \
  --token "<app-token>" \
  --comment "Gotify push notifications"
```

### Default Matcher

```bash
pvesh set /cluster/notifications/matchers/default-matcher \
  --target mail-to-root \
  --target gotify \
  --comment "Route all notifications to mail-to-root and Gotify" \
  --mode all
```

### Test

```bash
pvesh create /cluster/notifications/targets/gotify/test
```

---

## 15. Maintenance Reference

### Ceph Pool Operations

```bash
# Check health
ceph health detail
ceph osd df                 # OSD fill levels
ceph osd perf               # commit latency

# Temporarily allow pool delete
ceph osd pool set <pool> nodelete false
# ... delete ...
ceph osd pool set <pool> nodelete true

# Archive crash reports (after investigating)
ceph crash ls
ceph crash info <id>
ceph crash archive-all

# Check balancer
ceph balancer status
```

### OSD Recovery — Safe Reintegration Procedure

When bringing a pve3 OSD back after a period down, do **not** set reweight directly to 1.0. The ECMP routing fix must be in place first, then gradually increase weight to avoid flooding primaries.

```bash
# Step 1: Verify routing fix is active on pve2 and pve3
ssh pve2 systemctl is-active ceph-routing.service
ssh pve3 systemctl is-active ceph-routing.service

# Step 2: Start the OSD
ssh pve3 systemctl start ceph-osd@<id>

# Step 3: Reweight gradually (wait for HEALTH_WARN to stabilise between steps)
ceph osd reweight osd.<id> 0.05
# ... confirm heartbeats are working (no "Slow OSD heartbeats" or "possibly improving") ...
ceph osd reweight osd.<id> 0.1
ceph osd reweight osd.<id> 0.25
ceph osd reweight osd.<id> 0.5
ceph osd reweight osd.<id> 1.0

# Step 4: Restore primary-affinity once at full weight
ceph osd primary-affinity osd.<id> 1.0

# Monitor recovery
watch -n5 "ceph -s | grep -E '(health|pgs:|recovery)'"
```

**Heartbeat verification:** Before increasing weight past 0.1, confirm heartbeats between pve3 and pve2 OSDs are clean:

```bash
ceph health detail | grep -i 'slow.*heartbeat'
# Should show nothing, or "possibly improving" with decreasing ms values
```

### CRUSH Map Management

```bash
# Show current kubernetes_safe root contents
ceph osd crush dump | python3 -c "
import json,sys; d=json.load(sys.stdin)
for b in d['buckets']:
    if 'kubernetes' in b.get('name',''):
        print(b['name'], 'items:', [i['id'] for i in b['items']])"

# Add/remove pve3 from kubernetes_safe (e.g. during pve3 maintenance)
ceph osd crush link pve3 root=kubernetes_safe      # add back
ceph osd crush unlink pve3 root=kubernetes_safe    # remove

# Check primary-affinity for all OSDs
ceph osd dump | grep primary_affinity

# Temporarily lock an OSD out of primary elections (e.g. during recovery)
ceph osd primary-affinity osd.<id> 0
# Restore:
ceph osd primary-affinity osd.<id> 1.0
```

### Mon Leader Management

**Current state (2026-06-23):** `election_strategy classic`. pve1 is the mon leader (rank 0 always wins in classic mode). The `disallowed_leaders` mechanism only works with `connectivity` strategy and is currently a no-op.

**Root cause of recurring crashes (investigated 2026-06-23):**
- `mon.pve1` and `mon.pve3` both crashed with `MonitorDBStore::apply_transaction: ceph_abort_msg("failed to write to db")` — a Ceph 19.2.3 bug where any RocksDB write error causes an abort rather than a retry.
- The `connectivity` election strategy worsened this by writing connectivity scores to the mon DB on **every ping**, dramatically increasing write frequency and triggering the bug. Switching to `classic` eliminates that write path.
- `osd.0` and `osd.3` crash with a null pointer in `RocksDB::InternalStats::HandleBaseLevel` — a separate Ceph 19.2.3 bug in BlueStore's compaction path.
- NVMe temperature (previously ~70°C, now ~55°C after fan addition) was **not** a contributing factor: drive warning thresholds are 83–90°C, `Warning Temperature Time = 0` on all drives.
- Fix: upgrade to Ceph 19.2.4 when `19.2.4-pve*` lands in the Proxmox repo.

```bash
# Check current leader and election strategy
ceph mon stat
ceph mon dump | grep election_strategy

# To re-enable connectivity strategy after upgrading to 19.2.4+:
ceph mon set election_strategy connectivity
ceph mon add disallowed_leader pve1   # re-add if pve1 instability recurs

# To remove disallowed_leader restriction:
ceph mon rm disallowed_leader pve1
```

### Corosync Config Changes

Edit `/etc/pve/corosync.conf`, increment `config_version`, then reload on all nodes:

```bash
# Run on pve1, pve2, pve3 (can run in parallel)
corosync-cfgtool -R

# Verify all rings active
pvecm status
corosync-cfgtool -s        # link status per ring
```

### Kernel Management

List installed kernels:

```bash
proxmox-boot-tool kernel list
```

Remove old kernels (keeps current + one prior):

```bash
proxmox-boot-tool kernel clean
```

Current kernel: `7.0.6-2-pve`. Do not remove this or the immediately preceding version.

### HA Operations

```bash
# Check status
ha-manager status

# Migrate a VM manually
ha-manager migrate vm:<vmid> <target-node>

# Temporarily disable HA for a VM (for planned maintenance)
ha-manager set vm:<vmid> --state ignored

# Re-enable
ha-manager set vm:<vmid> --state started
```

### Node Maintenance (drain a node)

Before rebooting a node for kernel updates or hardware work:

```bash
# 1. Put node into maintenance (HA will migrate VMs away)
pvesh create /nodes/<node>/status --command startall  # opposite: drain
# Or from UI: Node -> More -> Maintenance Mode

# 2. Verify all VMs migrated
ha-manager status

# 3. Reboot
ssh <node> reboot

# 4. After node comes back, HA restores VMs per affinity rules
ha-manager status
```

### Maintenance Notes

- **Gotify token rotation:** `pvesh set /cluster/notifications/endpoints/gotify/gotify --token <new-token>`
