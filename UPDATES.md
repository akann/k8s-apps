# Cluster Updates & Incident Log

Chronological log of fixes, incidents, and resolved issues. For ongoing operational quirks that are part of the permanent setup, see the Appendix in [README.md](README.md).

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
