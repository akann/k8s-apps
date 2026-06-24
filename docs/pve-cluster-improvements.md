# Proxmox Cluster — Improvement Recommendations

> **Cluster:** cluster01 (pve1/pve2/pve3)  
> **Based on:** pve1 audit — 2026-06-19  
> **Scope:** All three Proxmox hypervisors  

Findings are grouped by area. Each item has a rationale and a concrete action — skip anything that doesn't fit your homelab goals.

---

## Table of Contents

1. [Corosync — Redundancy & Link Priority](#1-corosync--redundancy--link-priority)
2. [Ceph — Pool Protection & Safer Operations](#2-ceph--pool-protection--safer-operations)
3. [Ceph — Mon Crash Resilience](#3-ceph--mon-crash-resilience)
4. [Proxmox Firewall](#4-proxmox-firewall)
5. [VM & LXC Backups](#5-vm--lxc-backups)
6. [High Availability — K8s VM Coverage](#6-high-availability--k8s-vm-coverage)
7. [Notifications — Gotify Routing](#7-notifications--gotify-routing)
8. [TLS for PVE Web UI](#8-tls-for-pve-web-ui)
9. [Ceph MGR — Disable Unused Modules](#9-ceph-mgr--disable-unused-modules)
10. [DNS Redundancy](#10-dns-redundancy)
11. [Ceph — Pool Compression (Optional)](#11-ceph--pool-compression-optional)

---

## 1. Corosync — Redundancy & Link Priority

### Current state

```
totem {
  link_mode: passive
}
nodelist {
  node { name: pve1  ring0_addr: 192.168.22.11  ring1_addr: 10.10.20.1 }
  node { name: pve2  ring0_addr: 192.168.22.12  ring1_addr: 10.10.10.2 }
  node { name: pve3  ring0_addr: 192.168.22.13  ring1_addr: 10.10.30.2 }
}
```

Two links are configured:
- **ring0** — public management network (192.168.22.x), shared with VMs via vmbr0
- **ring1** — dedicated cluster network (10.10.x.x point-to-point, MTU 9000)

With `link_mode: passive`, ring0 carries all corosync traffic and ring1 sits idle until ring0 fails. This means:

- Cluster heartbeats and fencing decisions compete for bandwidth with VM traffic on vmbr0
- ring1 (the better network — dedicated, jumbo frames) is not being used
- A network storm or high VM I/O on vmbr0 can degrade corosync heartbeats

### Recommended change — swap link priority

The dedicated cluster network should be the primary corosync path. Change `knet_link_priority` so ring1 (cluster network) has higher priority than ring0 (public network):

```bash
# Run on one node — corosync reloads across the cluster
pvecm updatecerts  # ensure certs are current first

# Edit /etc/corosync/corosync.conf on ALL three nodes:
```

```
totem {
  link_mode: passive     # keep passive — one active at a time, cleaner for knet

  interface {
    linknumber: 0
    knet_link_priority: 1    # ring0 = public = LOW priority (failover only)
  }
  interface {
    linknumber: 1
    knet_link_priority: 2    # ring1 = cluster network = HIGH priority (primary)
  }
}
```

After editing all three nodes:

```bash
systemctl reload corosync   # on each node
pvecm status                # verify ring1 is now primary
```

**Alternative — switch to `link_mode: active`:** Both rings carry traffic simultaneously; corosync load-balances and achieves true redundancy. More bandwidth, but adds complexity (multipath corosync). For a 3-node homelab, `passive` with correct priority is simpler and sufficient.

---

## 2. Ceph — Pool Protection & Safer Operations

### 2a. Enable nodelete on production pools

Both active data pools (`rbd`, `kubernetes`) have `nodelete: false`. An accidental `ceph osd pool delete rbd rbd --yes-i-really-really-mean-it` would immediately destroy all VM disks.

```bash
ceph osd pool set rbd nodelete true
ceph osd pool set kubernetes nodelete true
# Verify:
ceph osd pool get rbd nodelete
ceph osd pool get kubernetes nodelete
```

This does not affect normal operation. To delete a protected pool in future, you must first `set nodelete false` — the extra step prevents accidents.

### 2b. Enable nopgchange on production pools (optional, stricter)

Prevents PG count changes on running pools (autoscaler is already managing this, but belt-and-suspenders):

```bash
ceph osd pool set rbd nopgchange true
ceph osd pool set kubernetes nopgchange true
```

### 2c. Reduce mon_osd_down_out_interval from 600s to 300s

Currently Ceph waits **10 minutes** before marking a down OSD as `out` and starting rebalancing. Given your NVMe OSDs are consumer-grade (with occasional crashes), a faster response to downed OSDs reduces the window where data is under-replicated.

```bash
ceph config set global mon_osd_down_out_interval 300
```

If you regularly reboot nodes (kernel updates via kured, etc.) and 5 minutes is too short for the OSD to come back, set to `360` instead.

---

## 3. Ceph — Mon Crash Resilience

These settings reduce the impact of the recurring mon.pve1 crash until the root hardware issue is resolved (see audit report section 3–4).

### 3a. Deprioritise pve1 as election leader

mon.pve1 is the current leader (election epoch 1186 — it has been elected hundreds of times and crashes regularly). Switching election strategy lets the cluster prefer a stable node as leader:

```bash
# Switch to connectivity-based elections
ceph mon set election_strategy connectivity

# Optionally, set pve1 as disallowed leader until crash is resolved:
# (This lets pve1 participate in quorum but not become leader)
# Note: only available with election_strategy connectivity
ceph mon add disallowed_leader pve1
```

To restore:

```bash
ceph mon rm disallowed_leader pve1
ceph mon set election_strategy classic
```

### 3b. Enable mon_compact_on_bootstrap

Already enabled (`mon_compact_on_trim: true`). No action needed.

### 3c. Add mon_warn_on_slow_ping_time threshold (visibility)

The current config logs to syslog at warning level. Add explicit slow-ping alerting so Ceph HEALTH_WARN surfaces network-related mon issues:

```bash
ceph config set mon mon_warn_on_slow_ping_time 250
```

---

## 4. Proxmox Firewall

### Current state

The Proxmox firewall is **not enabled** at either cluster or node level. The PVE web UI (port 8006) and SSH (port 22) are accessible to any host on 192.168.22.0/24 with no filtering.

For a homelab on a trusted private network this is a reasonable tradeoff, but consider enabling at minimum a node-level firewall to protect the management plane:

### Recommended — enable PVE firewall with management rules

In the PVE UI: **Datacenter → Firewall → Options → Enable: Yes**, then add rules. Or via CLI:

```bash
# Enable cluster firewall
pvesh set /cluster/firewall/options -enable 1

# Enable on pve1 node specifically
pvesh set /nodes/pve1/firewall/options -enable 1

# Add rules — allow management from your local network only
# PVE web UI
pvesh create /nodes/pve1/firewall/rules \
  -action ACCEPT -type in -proto tcp -dport 8006 \
  -source 192.168.22.0/24 -comment "PVE web UI"

# SSH
pvesh create /nodes/pve1/firewall/rules \
  -action ACCEPT -type in -proto tcp -dport 22 \
  -source 192.168.22.0/24 -comment "SSH management"

# Corosync (cluster internal)
pvesh create /nodes/pve1/firewall/rules \
  -action ACCEPT -type in -proto udp -dport 5404:5412 \
  -source 192.168.22.0/24 -comment "Corosync ring0"

pvesh create /nodes/pve1/firewall/rules \
  -action ACCEPT -type in -proto udp -dport 5404:5412 \
  -source 10.10.0.0/16 -comment "Corosync ring1"
```

**Note:** Enable on all three nodes. Confirm cluster connectivity still works after enabling before adding a DROP-all rule.

---

## 5. VM & LXC Backups

### Current state

No Proxmox backup jobs are configured (`pvesh get /cluster/backup` returns empty). The K8s workloads inside VMs are covered by Velero (cluster-level), but the **VM disks themselves** have no snapshot-based backup:

| VM/CT | Coverage | Gap |
|---|---|---|
| k8s-cp-1 (101) | Velero (K8s resources) | No VM-level disk backup |
| k8s-worker-1 (201) | Velero (K8s resources) | No VM-level disk backup |
| homepage (CT 401) | None | No backup at all |

If a VM disk is corrupted (not a K8s-level failure but a filesystem or OS failure), Velero cannot restore the VM — only its workloads.

### Recommended — add Proxmox backup jobs to CephFS

You already have `cephfs` storage with backup content type enabled. Configure scheduled vzdump backups:

```bash
# In PVE UI: Datacenter → Backup → Add
# Or via CLI (create backup job):
pvesh create /cluster/backup \
  -id k8s-vms \
  -storage cephfs \
  -schedule "sun 03:00" \
  -compress zstd \
  -mode snapshot \
  -vmid 101,201,401 \
  -mailnotification always \
  -prune-backups "keep-weekly=4,keep-monthly=2"
```

**Mode `snapshot`** works with Ceph RBD — it uses a temporary snapshot to produce a consistent backup without stopping the VM. The `cephfs` target gives you S3-independent local storage.

For the homepage LXC (CT 401 on pve3), adjust the node parameter when creating the job to run from pve3.

---

## 6. High Availability — K8s VM Coverage

### Current state

Only `ct:113` is enrolled in Proxmox HA. The K8s VMs rely on `onboot: 1` for automatic start, but this only triggers if the **same node** reboots. If pve1 goes down permanently (hardware failure), VMs 101 and 201 stay down unless manually migrated.

### Assessment

For a K8s cluster, the tradeoff is:
- **With HA:** VM migrates to another node within ~60–90s of node failure, K8s API server stays available
- **Without HA:** K8s loses the control-plane node (k8s-cp-1) and one worker. The remaining 2 control-plane nodes maintain quorum. K8s is degraded but not dead.

Given you have a 3-node K8s control plane, losing one node is survivable. However, adding HA costs nothing operationally and improves the recovery RTO significantly.

### Recommended — enroll K8s VMs in HA with node preferences

```bash
# Create HA group — prefer pve2/pve3 for k8s-cp-1 to avoid running on pve1
# (pve1 is currently crash-prone)
ha-manager groupadd k8s-cp \
  --nodes "pve2:2,pve3:2,pve1:1" \
  --comment "K8s control-plane VMs"

ha-manager groupadd k8s-worker \
  --nodes "pve1:2,pve2:2,pve3:2" \
  --comment "K8s worker VMs"

# Add VMs to HA (all nodes must see the VM)
ha-manager add vm:101 --group k8s-cp --max_restart 3 --max_relocate 2
ha-manager add vm:201 --group k8s-worker --max_restart 3 --max_relocate 2

# Verify
ha-manager status
```

The `pve1:1` preference weight keeps k8s-cp-1 off pve1 unless it's the only option — directly addressing the current stability concern.

---

## 7. Notifications — Gotify Routing

### Current state

A `gotify` notification endpoint is configured but the default matcher sends **only to `mail-to-root`** (local sendmail). Proxmox alerts (backup failures, HA events, node status) are not being delivered to Gotify — meaning they likely go nowhere in practice (mail-to-root requires a working local MTA).

### Recommended — add Gotify to the default matcher

In PVE UI: **Datacenter → Notifications → Matchers → default-matcher → Edit → Targets**, add `gotify`.

Or via API:

```bash
pvesh set /cluster/notifications/matchers/default-matcher \
  --target mail-to-root --target gotify
```

Also verify the Gotify endpoint is configured with your server URL and token:

```bash
pvesh get /cluster/notifications/endpoints/gotify
```

This means backup job results, HA failover events, and any cluster warnings will land in Gotify alongside your existing K8s alerts.

---

## 8. TLS for PVE Web UI

### Current state

The PVE web UI at `https://192.168.22.11:8006` (and similarly for pve2/pve3) uses **self-signed certificates**. Browsers warn on every visit and the cert cannot be pinned reliably.

You already use Cloudflare DNS-01 with Let's Encrypt for `*.yanatech.co.uk`. Proxmox has built-in ACME support with a Cloudflare DNS plugin.

### Recommended — configure PVE ACME per node

```bash
# 1. Register ACME account (once per cluster)
pvenode acme account register default your-email@example.com \
  --directory https://acme-v02.api.letsencrypt.org/directory

# 2. Add Cloudflare DNS plugin (needs CF API token with Zone:DNS:Edit)
pvenode acme plugin add dns cloudflare-dns \
  --api cf \
  --data "CF_Token=<your-token>"

# 3. Set the domain for each node (run on each host)
pvenode config set \
  --acme "account=default" \
  --acmedomain0 "domain=pve1.yanatech.co.uk,plugin=cloudflare-dns"

# 4. Issue the certificate
pvenode acme cert order
```

After this, `pve1.yanatech.co.uk` (add DNS A record → 192.168.22.11) gets a valid TLS cert. Add a Cloudflare A record for each node.

Certificates auto-renew via a systemd timer (`pvenode acme cert renew`).

---

## 9. Ceph MGR — Disable Unused Modules

The `nfs` mgr module is enabled (`on`) but NFS is not configured or used in this cluster. Unused loaded modules waste memory on the active MGR and increase the MGR's attack surface.

```bash
ceph mgr module disable nfs
```

Check what the NFS module has bound (should be nothing):

```bash
ceph nfs cluster ls 2>/dev/null   # should return empty
```

If you plan to use CephFS NFS exports in future, re-enable with `ceph mgr module enable nfs`.

---

## 10. DNS Redundancy

### Current state

All three nodes use a single DNS server: `192.168.22.1` (home router). If the router is rebooting or unreachable, PVE nodes cannot resolve external hostnames — this can affect:
- Package updates
- Let's Encrypt ACME challenges
- NTP server resolution
- Any cloud API calls from Proxmox

### Recommended — add a secondary resolver

Options:
1. **Use a local resolver** — if you run a Pi-hole, AdGuard Home, or any other DNS on your network, add it as `dns2`
2. **Use a public fallback** — add `1.1.1.1` or `9.9.9.9` as `dns2`

```bash
# On each PVE node (PVE will reflect this to /etc/resolv.conf):
pvesh set /nodes/pve1/dns -dns1 192.168.22.1 -dns2 1.1.1.1
pvesh set /nodes/pve2/dns -dns1 192.168.22.12 -dns2 1.1.1.1   # adjust pve2 addresses
pvesh set /nodes/pve3/dns -dns1 192.168.22.13 -dns2 1.1.1.1
```

**Note:** Your NTP configuration is already solid — 4 sources configured across multiple stratum-2 servers. No change needed there.

---

## 11. Ceph — Pool Compression (Optional)

### Current state

No compression is enabled on any pool. Compression is disabled by default for RBD block pools because:
- Block workloads (VM disks) often contain already-compressed data (OS files, container layers)
- Compression adds CPU overhead on the write path

### Assessment for your workload

| Pool | Content | Compression benefit |
|---|---|---|
| `rbd` | VM disks (K8s nodes — OS + containerd layers) | Low — container images are already compressed |
| `kubernetes` | K8s PVC data (Postgres WAL, MongoDB, Redis RDB) | Moderate — WAL and JSON data compresses well |
| `cephfs_data` | Backups, ISOs, snippets | High — backups and ISOs compress very well |

If you want to trial compression on the kubernetes pool:

```bash
# Enable snappy compression (low CPU cost, reasonable ratio)
ceph osd pool set kubernetes compression_mode aggressive
ceph osd pool set kubernetes compression_algorithm snappy
ceph osd pool set kubernetes compression_min_blob_size 8192

# Monitor ratio after 24h:
ceph osd pool stats kubernetes
```

For CephFS backup data, aggressive compression with zstd is worthwhile:

```bash
ceph osd pool set cephfs_data compression_mode aggressive
ceph osd pool set cephfs_data compression_algorithm zstd
```

---

## Summary Table

| # | Area | Effort | Impact | Priority |
|---|---|---|---|---|
| 1 | Corosync link priority — prefer cluster network | Low | Isolates corosync from VM traffic | High |
| 2a | Enable pool nodelete protection | Trivial | Prevents accidental pool deletion | High |
| 2c | mon_osd_down_out_interval 600→300 | Trivial | Faster recovery from OSD failures | Medium |
| 3a | Deprioritise pve1 as mon leader | Low | Reduces election churn during crash period | High (temporary) |
| 4 | Enable PVE firewall on management ports | Medium | Hardens management plane | Medium |
| 5 | Configure VM backup jobs to cephfs | Low | Covers VM-level recovery gap | High |
| 6 | Enroll K8s VMs in Proxmox HA | Low | Automatic VM migration on node failure | Medium |
| 7 | Route notifications to Gotify | Trivial | Ensures alerts are actually received | High |
| 8 | ACME TLS for PVE web UI | Medium | Trusted TLS on management portal | Low |
| 9 | Disable unused nfs MGR module | Trivial | Reduce MGR memory footprint | Low |
| 10 | Add secondary DNS server | Trivial | DNS resilience | Medium |
| 11 | Pool compression for kubernetes/cephfs | Low | Storage efficiency | Optional |
