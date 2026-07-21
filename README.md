# Servitium GitOps State

Argo CD reconciles this repository into the `servitium` namespace. The image
is always selected by immutable digest. The all-zero digest is a bootstrap
sentinel and must be replaced by the Servitium release workflow before the
Argo CD Application is enabled.

The ClusterIP service uses only the node's WireGuard address
`192.168.21.2` as an `externalIP`; it does not use host networking or a host
port. This keeps the namespace under Restricted Pod Security enforcement while
remaining reachable locally and through WireGuard. The manifest tests enforce
the exact non-root, read-only, capability-free container and reject host
namespaces and `hostPath` volumes.

Validate locally with:

```bash
bash tests/manifests.sh
kubectl kustomize . >/dev/null
```
