# ceph-csi-rbd

## Manual prerequisite

The `csi-rbd-secret` must exist in the `ceph-csi-rbd` namespace before syncing.
Contains the Ceph client key for `client.kubernetes`. Store in Vaultwarden.

```bash
kubectl create namespace ceph-csi-rbd

kubectl create secret generic csi-rbd-secret \
  --from-literal=userID=kubernetes \
  --from-literal=userKey=<ceph client.kubernetes key> \
  -n ceph-csi-rbd
```

To get the key from an existing cluster:
```bash
kubectl get secret csi-rbd-secret -n ceph-csi-rbd -o jsonpath='{.data.userKey}' | base64 -d
```

## Ceph cluster details
- FSID: 92197a62-7cf9-49eb-a0cb-5e0b9bbff52a
- Monitors: 192.168.22.11:6789, 192.168.22.12:6789, 192.168.22.13:6789
