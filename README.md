# Servitium GitOps State

Argo CD reconciles this repository into the `servitium` namespace. The image
is always selected by immutable digest. The all-zero digest is a bootstrap
sentinel and must be replaced by the Servitium release workflow before the
Argo CD Application is enabled.

The ClusterIP service declares only the node's WireGuard address
`192.168.21.2` as an `externalIP`; it does not allocate a LoadBalancer or
NodePort. The namespace NetworkPolicy admits direct WireGuard and administrator
LAN sources, while the host firewalls restrict Mihkel to this endpoint and keep
TCP 8099 out of the public allow-list. The manifest tests enforce the exact
non-root, read-only, capability-free container and reject host namespaces and
`hostPath` volumes.

Validate locally with:

```bash
bash tests/manifests.sh
kubectl kustomize . >/dev/null
```
