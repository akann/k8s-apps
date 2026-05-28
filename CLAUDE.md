# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Pure Kubernetes manifests repository for self-hosted infrastructure. No build system — all files are applied directly with `kubectl`.

## Applying Manifests

```bash
# Apply a single app (order matters: namespace first)
kubectl apply -f apps/uptime-kuma/namespace.yaml
kubectl apply -f apps/uptime-kuma/

# Apply all files in a directory recursively
kubectl apply -R -f apps/uptime-kuma/

# Diff before applying
kubectl diff -f apps/uptime-kuma/
```

## Repository Structure

```
apps/           # Self-hosted application workloads
  uptime-kuma/  # Monitoring dashboard (status.yanatech.co.uk)
  nextcloud/    # File storage (manifests pending)
  vaultwarden/  # Password manager (manifests pending)

infrastructure/ # Cluster-level components (applied once, rarely changed)
  cert-manager/ # TLS certificate automation
  metallb/      # Bare-metal load balancer
  monitoring/   # Monitoring stack
```

Each app directory is self-contained: `namespace.yaml`, `deployment.yaml`, `service.yaml`, `ingress.yaml`, and a `pvc.yaml` where persistent storage is needed.

## Conventions

- **Namespaces**: each app gets its own namespace matching the app name.
- **Storage**: PVCs use `storageClassName: ceph-rbd` (Ceph RBD block storage on the cluster).
- **Ingress**: NGINX ingress controller with `ingressClassName: nginx`. TLS via `wildcard-yanatech-tls` secret (covers `*.yanatech.co.uk`).
- **Hostnames**: apps are exposed as `<name>.yanatech.co.uk`.
- **Uptime Kuma ingress** sets extended proxy timeouts (`3600s`) because it uses WebSockets for live status updates — do the same for any WebSocket-heavy app.

## Adding a New App

1. Create `apps/<name>/namespace.yaml` with a dedicated namespace.
2. Add `deployment.yaml`, `service.yaml`, `ingress.yaml` following the uptime-kuma pattern.
3. Add `pvc.yaml` with `storageClassName: ceph-rbd` if persistent storage is needed.
4. Update `README.md` at the repo root.
