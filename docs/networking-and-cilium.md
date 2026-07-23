# Networking Deep Dive: Cilium Native Routing

How traffic actually moves through a 6-node bare-metal Kubernetes cluster, from the physical switch up to TLS termination — and the gotchas that come with running Cilium in native routing mode instead of the more common overlay/encapsulation mode.

## Physical and VLAN topology

The cluster runs on 3 Proxmox hypervisors (`pve1`-`pve3`), each hosting 2 of the cluster's 6 Kubernetes VMs (3 control planes, 3 workers). Two VLANs separate concerns on a single 8-port managed switch (TP-Link SG2008):

- **VLAN 22** — Proxmox management network, `192.168.22.0/24`
- **VLAN 33** — Kubernetes VM network, `192.168.33.0/24`

Inter-node Ceph replication and Corosync traffic don't touch the switch at all — each Proxmox node has direct 10GbE SFP+ DAC cables to the other two, forming a full mesh independent of the 2.5GbE management/VM network.

Kubernetes itself lives entirely on `192.168.33.x`: control planes at `.21`-`.23`, workers at `.31`-`.33`. The Ceph monitors backing cluster storage sit on the *management* network (`192.168.22.11`-`.13`), so any pod talking to Ceph is crossing VLANs through the router — a detail that matters below.

## CNI: Cilium in native routing mode

The cluster uses Cilium with **no encapsulation** (no VXLAN/Geneve overlay) — pod traffic is routed natively using the underlying network's own routing table, not tunneled. This is faster and simpler on a small bare-metal cluster, but it means Cilium can't rely on the encapsulation layer to enforce policy the way overlay mode does. Two consequences show up constantly:

1. **Standard `NetworkPolicy` doesn't fully work.** Cross-namespace ClusterIP-to-ClusterIP traffic and egress to IPs outside the pod CIDR (like the Ceph monitors on the management VLAN) require `CiliumNetworkPolicy` instead — plain `NetworkPolicy` objects are silently ineffective for these paths.
2. **Egress to raw IPs needs `toCIDR`.** Ceph CSI's egress to OSD ports (6802-6809) on `192.168.22.0/24` is defined via a `CiliumNetworkPolicy` with an explicit `toCIDR` block (`infrastructure/cilium/ciliumnetpol-ceph-osd.yaml`), because the destination isn't a Kubernetes-native endpoint Cilium can select by label.

Confirmed cases needing `CiliumNetworkPolicy` over standard `NetworkPolicy`: Grafana → Prometheus, Grafana → PostgreSQL (cross-namespace), the RAG chatbot's internal query path (`akan` namespace → `k8s-docs` namespace), and several on-prem-cloud-copilot subagents reaching Proxmox, Redis, Prometheus, Alertmanager, and MinIO across namespace boundaries.

## The "first policy flips the default" trap

Every namespace starts fully open — no `NetworkPolicy` or `CiliumNetworkPolicy` selecting any pod in it means unrestricted traffic in that direction. The moment *any* policy's selector matches a pod for a given direction (ingress or egress), that pod becomes default-deny for that direction against *every* rule that could apply — not just the new one being added.

In practice this means adding a narrow policy to a previously-unrestricted namespace, intended to open one new path, can silently close every other egress path that namespace's pods had — DNS resolution included. The fix is either to scope the new rule tightly to only the pods that need it, or to pair it with an explicit catch-all (`toEntities: [all]` / `egress: [{}]`) that preserves the namespace's original open posture alongside the new specific rule.

## Baseline network policy model

- Every namespace gets a `default-deny-all` `NetworkPolicy` as a baseline.
- Every namespace running an operator or controller that talks to the Kubernetes API needs an explicit `allow-kube-apiserver-egress` rule (ports 443, 6443, 53) — this is not implicit even for in-cluster traffic.
- CNPG's Postgres operator has a per-namespace egress *allowlist*, not a wildcard: every new namespace hosting a CNPG cluster has to be added to that list before the operator can query its instances' status, or the operator fails indefinitely with an instance-status-extraction timeout that looks unrelated to the missing allowlist entry.

## Load balancing and ingress

MetalLB hands out a small pool of LAN IPs (`192.168.33.200-249`) for `LoadBalancer`-type services — one for ingress-nginx, one for the Kong API gateway. ingress-nginx runs with `externalTrafficPolicy: Local` rather than the default `Cluster`, specifically so that Cloudflare-proxied traffic's real visitor IP survives into the access logs: `Cluster` mode lets kube-proxy SNAT the source to a node IP before the request reaches the pod, which would make every visitor look like they're coming from inside the cluster and would break the Cloudflare-range IP trust check used to log real client IPs.

## TLS

cert-manager issues wildcard certificates via Let's Encrypt's DNS-01 challenge against Cloudflare, one per DNS zone the cluster serves (`*.yanatech.co.uk`, `*.nkweini.org`, `*.dovehousett.org`). Each zone's Cloudflare API token is scoped to that zone only. Reflector then copies each wildcard certificate's Secret into every namespace that needs it, so individual apps don't each need their own cert-manager `Certificate` resource — they just reference the reflected Secret by name.
