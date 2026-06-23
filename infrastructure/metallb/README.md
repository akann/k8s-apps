# MetalLB

Bare-metal load balancer for Kubernetes. Installed via Helm, configured via CRDs in this directory.

## Helm Install

```bash
helm repo add metallb https://metallb.github.io/metallb
helm repo update
helm install metallb metallb/metallb -n metallb-system --create-namespace
```

## Apply Configuration

After the Helm install, apply the IP pool and L2 advertisement:

```bash
kubectl apply -f infrastructure/metallb/ipaddresspool.yaml
kubectl apply -f infrastructure/metallb/l2advertisement.yaml
```

## Configuration

| Setting | Value |
|---------|-------|
| Mode | L2Advertisement |
| IP Pool | `192.168.22.200 – 192.168.22.249` |
| Ingress VIP | `192.168.22.200` (ingress-nginx) |

The ingress-nginx `LoadBalancer` service picks up `192.168.22.200` from this pool. pfSense NATs `62.3.101.138:80/443` to that VIP.
