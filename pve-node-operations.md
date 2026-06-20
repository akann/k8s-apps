# PVE Node Operations — Adding and Replacing Cluster Nodes

> **Cluster:** cluster01  
> **Current nodes:** pve1 (192.168.22.11) / pve2 (192.168.22.12) / pve3 (192.168.22.13)  
> **Last updated:** 2026-06-19  

This document covers two scenarios:

1. **[Replacing a node](#replacing-a-node)** — swap out identical hardware for the same hostname and role (most common)
2. **[Adding a new node](#adding-a-new-node-pve4)** — scale the cluster from 3 to 4 nodes

---

## Table of Contents

1. [Hardware Reference](#1-hardware-reference)
2. [Replacing a Node](#2-replacing-a-node)
   - [2.1 Pre-checks](#21-pre-checks)
   - [2.2 Evacuate the Failing Node](#22-evacuate-the-failing-node)
   - [2.3 Remove Ceph Daemons](#23-remove-ceph-daemons)
   - [2.4 Remove from PVE Cluster](#24-remove-from-pve-cluster)
   - [2.5 Prepare Replacement Hardware](#25-prepare-replacement-hardware)
   - [2.6 Rejoin the Cluster](#26-rejoin-the-cluster)
   - [2.7 Restore Network Config](#27-restore-network-config)
   - [2.8 Restore FRR / OSPF](#28-restore-frr--ospf)
   - [2.9 Restore Ceph Daemons](#29-restore-ceph-daemons)
   - [2.10 Restore Firewall Rules](#210-restore-firewall-rules)
   - [2.11 Restore VMs and HA](#211-restore-vms-and-ha)
   - [2.12 Final Verification](#212-final-verification)
3. [Adding a New Node (pve4)](#3-adding-a-new-node-pve4)
   - [3.1 Cluster Network Topology Constraint](#31-cluster-network-topology-constraint)
   - [3.2 New Node Addressing](#32-new-node-addressing)
   - [3.3 Install PVE on New Hardware](#33-install-pve-on-new-hardware)
   - [3.4 Network Configuration](#34-network-configuration)
   - [3.5 FRR / OSPF on pve4](#35-frr--ospf-on-pve4)
   - [3.6 Join the Cluster](#36-join-the-cluster)
   - [3.7 Add Ceph Daemons](#37-add-ceph-daemons)
   - [3.8 Add Firewall Rules](#38-add-firewall-rules)
   - [3.9 Final Verification](#39-final-verification)
4. [Reference: Node-Specific Values](#4-reference-node-specific-values)

---

## 1. Hardware Reference

All current nodes are identical. A replacement must use the same NIC model (or have matching PCI names) for the network config to apply without changes.

| Component | Spec |
|---|---|
| CPU | Intel Core i5-12600H — 12c/16t |
| RAM | 64 GiB DDR5 |
| NIC cluster | Intel X710 10GbE SFP+ dual-port — `enp2s0f0np0`, `enp2s0f1np1` |
| NIC public | Intel I226-V 2.5GbE — `enp87s0` |
| NIC secondary | Intel I226-LM 2.5GbE — `enp90s0` |
| WiFi | MediaTek MT7922 — leave `DOWN`, never configure |
| NVMe OS | Crucial CT500P3PSSD8 — 465.8 GB (slot: nvme1) |
| NVMe OSD large | Lexar NM790 2 TB (slot: nvme0) |
| NVMe OSD small | Lexar NM790 1 TB (slot: nvme2) |

**NVMe slot order is fixed by physical slot, not by Lexar label.** Always verify with `lsblk -d -o NAME,SIZE,MODEL` before touching disks.

---

## 2. Replacing a Node

Use this procedure when replacing a damaged or failed node with identical hardware. The replacement takes the same hostname, IP, and role as the original.

**Time estimate:** 1–2 hours for a planned replacement. Add 30 min if the node died unexpectedly and Ceph is unhealthy.

### 2.1 Pre-checks

Run from any surviving node.

```bash
# Cluster quorum
pvecm status

# Ceph health — must be HEALTH_OK or HEALTH_WARN (degraded is OK, but not HEALTH_ERR)
ceph health detail
ceph osd tree          # confirm all OSDs on other nodes are up
ceph mon stat          # confirm quorum includes both surviving nodes

# HA status
ha-manager status
```

With a 3-node cluster, losing one node drops quorum to 2 nodes — the cluster stays up but cannot make quorum decisions. Ceph with `min-size 2` will keep serving data as long as 2 of 3 OSDs per PG are up. Do not proceed if Ceph is already in HEALTH_ERR.

### 2.2 Evacuate the Failing Node

If the node is still reachable, migrate VMs gracefully. If it is unreachable (dead), HA has already migrated VMs — skip to 2.3.

```bash
# From pve1 shell (or any surviving node via pvesh targeting the failing node):

# Option A: put node in maintenance mode (preferred — HA migrates everything)
# In PVE UI: Node → More → Maintenance Mode
# Or via API:
pvesh create /nodes/<failing-node>/maintenance --enabled 1

# Monitor migration
ha-manager status     # wait until no resources show <failing-node> as current node
watch -n2 "qm list"  # cross-check all VMs are now on other nodes

# Option B: manual live migration of each VM
qm migrate <vmid> <target-node> --online 1
```

For the template VM (9000) and any stopped VMs, cold-migrate:

```bash
qm migrate 9000 pve2   # or pve3 — wherever has free local-lvm space
```

### 2.3 Remove Ceph Daemons

Run from a **surviving** node. Replace `<node>` with the node being removed (e.g. `pve1`).

**OSDs first.** The rebalance will start immediately after each OSD is removed — Ceph will replicate the data to the remaining OSDs.

```bash
# Mark OSDs out (Ceph starts rebalancing data off them)
ceph osd out osd.<id>   # e.g. osd.0 and osd.3 for pve1

# Wait for rebalance — do not proceed until HEALTH_OK
watch -n5 ceph health

# Confirm no PGs are on these OSDs anymore
ceph osd df            # check the OSDs show 0 PGs

# Stop the OSD services (run on failing node if still reachable, else skip)
ssh <node> systemctl stop ceph-osd@<id>

# Remove OSDs from CRUSH map and cluster
ceph osd purge osd.<id> --yes-i-really-mean-it   # repeat for each OSD on the node
```

**MDS:**

```bash
ceph mds fail mds.<node>   # e.g. mds.pve1
# A standby MDS will take over automatically
ceph fs status             # confirm active MDS is on another node
```

**MGR:**

```bash
# If this is the active mgr, trigger failover first
ceph mgr fail <node>       # e.g. pve1
ceph mgr stat              # confirm another node is now active
```

**MON (last):**

```bash
ceph mon remove <node>     # e.g. pve1
ceph mon stat              # confirm quorum still holds on 2 remaining mons
```

### 2.4 Remove from PVE Cluster

If the node is still online, shut it down first:

```bash
ssh <node> poweroff
```

Then from a surviving node:

```bash
pvecm delnode <node>    # e.g. pvecm delnode pve1
pvecm nodes             # confirm it's gone
```

If the node is unreachable and `pvecm delnode` fails, force removal:

```bash
# On each surviving node, edit corosync.conf — remove the dead node's stanza
# Then reload:
corosync-cfgtool -R
pvecm expected 2        # if you're left with 2 nodes and need quorum
```

### 2.5 Prepare Replacement Hardware

Install Proxmox VE 9 from the official ISO onto the **Crucial NVMe only** (nvme1n1 — 465 GB). Leave the two Lexar drives untouched if you plan to reuse them, or wipe and re-provision them as fresh OSDs.

**Installer settings:**

| Setting | Value |
|---|---|
| Target disk | Crucial 465 GB NVMe (NOT the Lexar drives) |
| Filesystem | `ext4` |
| Hostname | same as original: `pve1.akan.home` / `pve2.akan.home` / `pve3.akan.home` |
| IP address | same as original (see §4) |
| Gateway | `192.168.22.1` |
| DNS | `192.168.22.1` |

After install, set up APT repositories before touching anything else:

**`/etc/apt/sources.list.d/proxmox.sources`**
```
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
```

**`/etc/apt/sources.list.d/ceph.sources`**
```
Types: deb
URIs: http://download.proxmox.com/debian/ceph-squid
Suites: trixie
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
```

Disable the enterprise repo in `/etc/apt/sources.list.d/pve-enterprise.sources` (comment all lines).

**`/etc/apt/sources.list.d/debian.sources`**
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

```bash
apt update && apt full-upgrade -y
```

### 2.6 Rejoin the Cluster

From the **replacement node**, join the existing cluster. Use pve2 or pve3 as the join target:

```bash
pvecm add 192.168.22.12    # join via pve2 (or .13 for pve3)
```

`pvecm add` will prompt for pve2's root password, sync `/etc/pve`, and register the node. After this completes:

```bash
pvecm status     # should show 3 nodes, Quorate: Yes
pvecm nodes
```

The cluster filesystem (pmxcfs) syncs `storage.cfg`, firewall rules, and HA config automatically. Do not manually copy these files.

### 2.7 Restore Network Config

The installer creates a minimal `/etc/network/interfaces` with only `vmbr0`. Replace it with the full config for this node.

Find the node-specific values in §4 and write `/etc/network/interfaces`:

**Example for pve1:**

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
    bridge-vids 33 44 55 66
```

Apply:

```bash
ifreload -a
# Verify cluster links are up
ping 10.10.10.2 -c3    # pve2 cluster link
ping 10.10.20.2 -c3    # pve3 cluster link
```

Set DNS:

```bash
pvesh set /nodes/<node>/dns --dns1 192.168.22.1 --dns2 1.1.1.1 --search akan.home
```

### 2.8 Restore FRR / OSPF

```bash
apt install frr -y
```

Enable OSPF in `/etc/frr/daemons`:
```
ospfd=yes
```

Write `/etc/frr/frr.conf` — use node-specific values from §4. Example for pve1:

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

```bash
systemctl enable --now frr

# Verify adjacencies (expect 2 FULL neighbors)
vtysh -c "show ip ospf neighbor"
vtysh -c "show ip route ospf"
```

### 2.9 Restore Ceph Daemons

**MON:**

```bash
pveceph mon create   # run on the rejoined node itself
ceph mon stat        # verify quorum shows all 3 mons
```

**MGR:**

```bash
pveceph mgr create
ceph mgr stat
```

**MDS:**

```bash
pveceph mds create
ceph fs status       # confirm 3 MDS daemons (1 active, 2 standby)
```

**OSDs:** If the Lexar drives were wiped or are new, provision them fresh:

```bash
pveceph osd create /dev/nvme0n1   # 2 TB Lexar
pveceph osd create /dev/nvme2n1   # 1 TB Lexar
```

If the drives still have data from before the node failure, Ceph will detect the existing OSD UUIDs and reuse them. Watch for rebalancing to complete:

```bash
watch -n5 "ceph health; ceph osd df"
# Wait until HEALTH_OK and all PGs are active+clean
```

Apply the Ceph tuning (runtime config — stored in mon DB, not in ceph.conf):

```bash
ceph config set global mon_osd_down_out_interval 300
ceph config set mon mon_warn_on_slow_ping_time 250
ceph mon set election_strategy connectivity
```

If pve1 should remain disallowed as mon leader (due to ongoing crash issue):

```bash
ceph mon add disallowed_leader pve1
```

### 2.10 Restore Firewall Rules

The cluster filesystem syncs firewall rules to all nodes automatically after `pvecm add`. Verify the rules arrived and are enabled:

```bash
pvesh get /nodes/<node>/firewall/rules
# Each rule must have "enable": 1
```

If rules are present but disabled (can happen if the node rejoined before rules existed):

```bash
for pos in $(pvesh get /nodes/<node>/firewall/rules --output-format json | jq '.[].pos'); do
  pvesh set /nodes/<node>/firewall/rules/$pos --enable 1
done
```

Enable the node firewall:

```bash
pvesh set /nodes/<node>/firewall/options --enable 1
```

### 2.11 Restore VMs and HA

The VM configs sync via pmxcfs — they will already be visible in the PVE UI. If the node was the primary for any VMs not yet migrated back, HA will redistribute them per affinity rules automatically.

Verify HA state:

```bash
ha-manager status
```

If any VM is stuck in an unexpected state:

```bash
ha-manager set vm:<vmid> --state started
```

For the VM template (9000) — if it was migrated away during evacuation, migrate it back or leave it where it is (templates on any node are accessible cluster-wide via pmxcfs).

### 2.12 Final Verification

```bash
# Cluster
pvecm status                          # 3 nodes, Quorate: Yes
pvecm nodes

# OSPF
vtysh -c "show ip ospf neighbor"      # 2 FULL neighbors

# Ceph
ceph health                           # HEALTH_OK
ceph osd tree                         # 6 OSDs, all up/in
ceph mon stat                         # 3 mons in quorum
ceph fs status                        # 1 active MDS + 2 standby

# HA
ha-manager status                     # all resources started

# Firewall
iptables -L PVEFW-HOST-IN -n -v --line-numbers   # rules present with counters
```

---

## 3. Adding a New Node (pve4)

### 3.1 Cluster Network Topology Constraint

The current cluster network uses **direct point-to-point /30 links** on the Intel X710 dual-port SFP+ NICs. Each node uses both ports to connect directly to the other two nodes.

Adding a 4th node creates a problem: with only 2 SFP+ ports per node, pve4 can directly connect to at most 2 of the 3 existing nodes — it cannot form a full mesh without a 3rd port. Likewise, one existing node would only have pve4 reachable via OSPF over a single hop rather than directly.

**Options:**

| Option | Pros | Cons |
|---|---|---|
| Add a 10GbE switch to the cluster network | Clean full mesh for 4+ nodes, existing NICs unchanged | Switch cost, new cabling |
| Accept partial mesh — pve4 connects to pve1 and pve2 only; pve3↔pve4 via OSPF | No new hardware | One hop between pve3 and pve4, single point of failure for that path |
| Repurpose vmbr1 (I226-LM 2.5GbE) for cluster traffic | No switch needed | Drops cluster bandwidth to 2.5GbE, loses separate storage network benefit |

**Recommended approach (switch):** Add a 10GbE switch (or SFP+ DAC switch) and rewire the cluster network so all nodes connect to the switch via one X710 port each, leaving the second port as a bond or spare. OSPF continues to work, adjacencies form over the switch fabric. Update `/etc/network/interfaces` on each node to reflect the new addresses.

The instructions below assume the **partial mesh** option (no new hardware) since it keeps complexity low for a 4th identical mini-PC.

### 3.2 New Node Addressing

| Property | Value |
|---|---|
| Hostname | `pve4.akan.home` |
| Management IP | `192.168.22.14/24` |
| OSPF loopback | `10.255.255.4/32` |
| vmbr1 IP | `192.168.33.14/24` |
| Link to pve1 | pve4: `10.10.40.2/30`, pve1: `10.10.40.1/30` |
| Link to pve2 | pve4: `10.10.50.2/30`, pve2: `10.10.50.1/30` |

pve3 reaches pve4 via OSPF through pve1 or pve2.

**On pve1** — add new link interface to `/etc/network/interfaces`:

```
auto enp2s0f1np1       # previously used for pve1→pve3; now used for pve1→pve4
iface enp2s0f1np1 inet static
    address 10.10.40.1/30
    mtu 9000
```

Wait — pve1's `enp2s0f1np1` is currently used for the pve1→pve3 link (10.10.20.0/30). This is the conflict. With identical hardware, there's no free X710 port on pve1 for a direct link to pve4 without dropping the pve1→pve3 link.

**Practical resolution:** connect pve4 via `enp2s0f0np0 → pve2` and `enp2s0f1np1 → pve3` (reuse pve2 and pve3's free port slots), and reach pve1 via OSPF:

| Link | pve4 port | pve4 addr | Remote port | Remote addr |
|---|---|---|---|---|
| pve4 → pve2 | enp2s0f0np0 | 10.10.40.2/30 | enp2s0f1np1 (currently pve2→pve3) | 10.10.40.1/30 |
| pve4 → pve3 | enp2s0f1np1 | 10.10.50.2/30 | enp2s0f0np0 (currently pve3→pve1) | 10.10.50.1/30 |

This frees the pve2→pve3 link and pve3→pve1 link for reconnection to pve4, but requires cable repatching. Plan this carefully during a maintenance window.

### 3.3 Install PVE on New Hardware

Same as §2.5. Use:

- Hostname: `pve4.akan.home`
- IP: `192.168.22.14/24`
- Gateway: `192.168.22.1`

Set up APT repos identically to existing nodes (see §2.5).

### 3.4 Network Configuration

Write `/etc/network/interfaces` on **pve4**:

```
auto lo
iface lo inet loopback

auto lo:ospf
iface lo:ospf inet static
    address 10.255.255.4/32

iface enp87s0 inet manual
iface enp90s0 inet manual

auto enp2s0f0np0
iface enp2s0f0np0 inet static
    address 10.10.40.2/30
    mtu 9000

auto enp2s0f1np1
iface enp2s0f1np1 inet static
    address 10.10.50.2/30
    mtu 9000

auto vmbr0
iface vmbr0 inet static
    address 192.168.22.14/24
    gateway 192.168.22.1
    bridge-ports enp87s0
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 22 111

auto vmbr1
iface vmbr1 inet static
    address 192.168.33.14/24
    bridge-ports enp90s0
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 33 44 55 66
```

Also update `/etc/network/interfaces` on **pve2** and **pve3** to replace the affected link addresses, then `ifreload -a` on each node.

### 3.5 FRR / OSPF on pve4

Install FRR and enable `ospfd=yes` in `/etc/frr/daemons`.

Write `/etc/frr/frr.conf` on pve4:

```
frr version 10.3.1
frr defaults traditional
hostname pve4
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
 ospf router-id 10.255.255.4
 timers throttle spf 10 100 500
 passive-interface default
 network 10.10.40.0/30 area 0
 network 10.10.50.0/30 area 0
 network 10.255.255.4/32 area 0
exit
```

Also add the new prefixes to the FRR configs on pve2 and pve3 (`network 10.10.40.0/30` / `10.10.50.0/30`) and reload: `systemctl reload frr`.

```bash
systemctl enable --now frr
vtysh -c "show ip ospf neighbor"   # expect 2 FULL neighbors (pve2, pve3)
vtysh -c "show ip route ospf"      # expect 10.255.255.1-3 routes via OSPF
```

### 3.6 Join the Cluster

```bash
pvecm add 192.168.22.12 --link0 192.168.22.14 --link1 10.10.40.2
```

`--link0` is the management ring, `--link1` is the cluster ring (using pve4's direct link to pve2). After this:

```bash
pvecm status    # 4 nodes, Quorate: Yes
pvecm nodes
```

Update `/etc/pve/corosync.conf` to add the pve4 node stanza (pmxcfs manages this, but verify it's correct):

```
node {
  name: pve4
  nodeid: 4
  quorum_votes: 1
  ring0_addr: 192.168.22.14
  ring1_addr: 10.10.40.2
}
```

Increment `config_version` and reload on all nodes:

```bash
# Run on pve1, pve2, pve3, pve4
corosync-cfgtool -R
```

With 4 nodes, quorum requires 3. Verify:

```bash
pvecm status   # Expected quorum votes: 4, Total votes: 4
```

### 3.7 Add Ceph Daemons

**MON:**

```bash
pveceph mon create   # run on pve4
ceph mon stat        # 4 mons in quorum
```

Ceph recommends an odd number of monitors (3, 5). With 4 mons, you have redundancy but not the cleanest split-brain handling. Either add a 5th mon elsewhere or accept 4.

**MGR:**

```bash
pveceph mgr create
```

**MDS:**

```bash
pveceph mds create
```

**OSDs:**

```bash
pveceph osd create /dev/nvme0n1   # 2 TB Lexar
pveceph osd create /dev/nvme2n1   # 1 TB Lexar

# New OSDs: osd.6 and osd.7 (next available IDs)
watch -n5 ceph health             # wait for rebalance and HEALTH_OK
```

Update `ceph.conf` to add pve4's mon:

```ini
[mon.pve4]
    public_addr = 192.168.22.14
```

and add `192.168.22.14` to `mon_host`. This file is at `/etc/ceph/ceph.conf` — edit on one node; pmxcfs distributes it.

### 3.8 Add Firewall Rules

Firewall rules are per-node. Add the same rule set to pve4:

```bash
node=pve4

# SSH - cluster LAN
pvesh create /nodes/$node/firewall/rules --type in --action ACCEPT --proto tcp --dport 22 --source 192.168.22.0/24 --enable 1
# SSH - laptop
pvesh create /nodes/$node/firewall/rules --type in --action ACCEPT --proto tcp --dport 22 --source 192.168.11.0/24 --enable 1
# PVE UI - cluster LAN
pvesh create /nodes/$node/firewall/rules --type in --action ACCEPT --proto tcp --dport 8006 --source 192.168.22.0/24 --enable 1
# PVE UI - laptop
pvesh create /nodes/$node/firewall/rules --type in --action ACCEPT --proto tcp --dport 8006 --source 192.168.11.0/24 --enable 1
# ICMP - cluster LAN
pvesh create /nodes/$node/firewall/rules --type in --action ACCEPT --proto icmp --source 192.168.22.0/24 --enable 1
# ICMP - laptop
pvesh create /nodes/$node/firewall/rules --type in --action ACCEPT --proto icmp --source 192.168.11.0/24 --enable 1
# Corosync ring0
pvesh create /nodes/$node/firewall/rules --type in --action ACCEPT --proto udp --dport 5404:5412 --source 192.168.22.0/24 --enable 1
# Corosync ring1
pvesh create /nodes/$node/firewall/rules --type in --action ACCEPT --proto udp --dport 5404:5412 --source 10.10.0.0/16 --enable 1
# Ceph cluster network (all)
pvesh create /nodes/$node/firewall/rules --type in --action ACCEPT --source 10.10.0.0/16 --enable 1
# Ceph mon v2
pvesh create /nodes/$node/firewall/rules --type in --action ACCEPT --proto tcp --dport 3300 --source 192.168.22.0/24 --enable 1
# Ceph mon v1
pvesh create /nodes/$node/firewall/rules --type in --action ACCEPT --proto tcp --dport 6789 --source 192.168.22.0/24 --enable 1
# Ceph OSD
pvesh create /nodes/$node/firewall/rules --type in --action ACCEPT --proto tcp --dport 6800:7300 --source 192.168.22.0/24 --enable 1

# Enable node firewall
pvesh set /nodes/$node/firewall/options --enable 1
```

Verify all rules show `enable: 1`:

```bash
pvesh get /nodes/$node/firewall/rules
```

### 3.9 Final Verification

```bash
pvecm status                          # 4 nodes, Quorate: Yes
vtysh -c "show ip ospf neighbor"      # 2 FULL neighbors from pve4 perspective
ceph health                           # HEALTH_OK
ceph osd tree                         # 8 OSDs, all up/in
ceph mon stat                         # 4 mons in quorum
ha-manager status                     # all resources accounted for
```

Place a test VM on pve4 and verify Ceph RBD works:

```bash
qm clone 9000 999 --name test-pve4 --full --storage rbd --target pve4
qm start 999
qm status 999   # running
qm stop 999
qm destroy 999
```

---

## 4. Reference: Node-Specific Values

### Addressing Table

| Property | pve1 | pve2 | pve3 | pve4 (if added) |
|---|---|---|---|---|
| Management IP | 192.168.22.11 | 192.168.22.12 | 192.168.22.13 | 192.168.22.14 |
| vmbr1 IP | 192.168.33.11 | 192.168.33.12 | 192.168.33.13 | 192.168.33.14 |
| OSPF loopback | 10.255.255.1 | 10.255.255.2 | 10.255.255.3 | 10.255.255.4 |
| Corosync nodeid | 1 | 2 | 3 | 4 |

### Cluster Links

| Link | pve1 end | pve2 end | pve3 end |
|---|---|---|---|
| pve1 ↔ pve2 | 10.10.10.1/30 (enp2s0f0np0) | 10.10.10.2/30 (enp2s0f0np0) | — |
| pve1 ↔ pve3 | 10.10.20.1/30 (enp2s0f1np1) | — | 10.10.20.2/30 (enp2s0f0np0) |
| pve2 ↔ pve3 | — | 10.10.30.1/30 (enp2s0f1np1) | 10.10.30.2/30 (enp2s0f1np1) |

### Ceph OSD Assignment

| OSD | Node | Device | Size |
|---|---|---|---|
| osd.0 | pve1 | nvme0n1 (Lexar 2 TB) | 1.86 TiB |
| osd.1 | pve2 | nvme0n1 (Lexar 2 TB) | 1.86 TiB |
| osd.2 | pve3 | nvme0n1 (Lexar 2 TB) | 1.86 TiB |
| osd.3 | pve1 | nvme2n1 (Lexar 1 TB) | 0.93 TiB |
| osd.4 | pve2 | nvme2n1 (Lexar 1 TB) | 0.93 TiB |
| osd.5 | pve3 | nvme2n1 (Lexar 1 TB) | 0.93 TiB |
| osd.6 | pve4 | nvme0n1 (Lexar 2 TB) | 1.86 TiB |
| osd.7 | pve4 | nvme2n1 (Lexar 1 TB) | 0.93 TiB |

### OSPF Networks per Node

| Node | Networks announced |
|---|---|
| pve1 | 10.10.10.0/30, 10.10.20.0/30, 10.255.255.1/32 |
| pve2 | 10.10.10.0/30, 10.10.30.0/30, 10.255.255.2/32 |
| pve3 | 10.10.20.0/30, 10.10.30.0/30, 10.255.255.3/32 |
| pve4 | 10.10.40.0/30, 10.10.50.0/30, 10.255.255.4/32 |

### Corosync Ring1 Addresses

Each node's `ring1_addr` in corosync is the IP of its direct cluster link used for the high-priority ring. The links must be OSPF-reachable from all nodes.

| Node | ring1_addr | Physical link |
|---|---|---|
| pve1 | 10.10.20.1 | enp2s0f1np1 → pve3 |
| pve2 | 10.10.10.2 | enp2s0f0np0 → pve1 |
| pve3 | 10.10.30.2 | enp2s0f1np1 → pve2 |
| pve4 | 10.10.40.2 | enp2s0f0np0 → pve2 |
