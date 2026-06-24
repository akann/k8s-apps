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
