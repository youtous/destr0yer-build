# Private Registry

Decisions: [ADR-015](adr/015-private-registry.md) (pull-through cache),
[ADR-017](adr/017-k3s-registries-yaml.md) (registries.yaml)

## Overview

A pull-through container registry caches images from upstream registries
(docker.io, ghcr.io, quay.io) on a local PVC. K3S nodes are configured via
`registries.yaml` to pull through the cache instead of hitting upstream
directly.

```
containerd (K3S node)
    │ pull docker.io/library/nginx
    ▼
registries.yaml → redirect to http://127.0.0.1:15000
    │
    ▼ NodePort
registry pod (3 sidecars: docker.io, ghcr.io, quay.io)
    │ cache miss?
    ▼
upstream registry (docker.io, ghcr.io, quay.io)
```

## In-cluster registry

**Kluctl raw manifests**: `kluctl/storage/registry/`.

One pod with three sidecar containers, each proxying a different upstream:

| Upstream | Container port | NodePort |
|----------|---------------|----------|
| `docker.io` | 5000 | 15000 |
| `ghcr.io` | 5001 | 15001 |
| `quay.io` | 5002 | 15002 |

- **Image**: `registry:2.8.3`
- **Storage**: 10Gi PVC on `openebs-hostpath`, filesystem driver, 168h TTL
- **Service type**: `NodePort` (so host-level containerd can reach it — cluster
  DNS is unavailable to containerd)

## K3S node configuration

**Ansible role**: `roles/k3s_registry/`, invoked by `playbooks/02-k3s.yml`.

Templates `/etc/rancher/k3s/registries.yaml` on each node:

```yaml
mirrors:
  docker.io:
    endpoint: ["http://127.0.0.1:15000"]
  ghcr.io:
    endpoint: ["http://127.0.0.1:15001"]
  quay.io:
    endpoint: ["http://127.0.0.1:15002"]
```

TLS verification is skipped (`insecure_skip_verify: true`) since the mirrors
are plain HTTP on localhost. K3S restarts on config change.

**Bootstrap order**: deploy registry via Kluctl first, verify cache is healthy,
then add `k3s_installation_registries` mirrors to the inventory and re-run `just k3s`.

## Operations

```sh
just deploy-only storage/registry  # redeploy registry pod
just k3s                           # re-run K3S playbook (updates registries.yaml)
```

Gatus monitors registry health via `registry.registry.svc:5000/v2/`.
