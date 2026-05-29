# ADR-015: Private registry with pull-through cache

**Status**: Implemented

**Multi-arch audit (2026-05-26)**: All images verified for ARM64 + AMD64 support.

| Image | Multi-arch | Notes |
|-------|-----------|-------|
| alpine:3.21 | ✅ | |
| alpine/k8s:1.32.13 | ✅ | |
| crowdsecurity/crowdsec:v1.7.6 | ✅ | |
| mariadb-operator:26.3.0 | ✅ arm64+amd64 | |
| mariadb:10.11 | ✅ | |
| eclipse-mosquitto:2.1.2-alpine | ✅ | Fixed: was using non-existent `2.1.2` tag |
| koenkk/zigbee2mqtt:2.10.1 | ✅ | |
| seafileltd/seafile-mc:13.0.21 | ✅ | |
| wdes/mail-autodiscover-autoconfig | ✅ | |
| dxflrs/garage:v1.1.0 | ✅ | |
| authelia/authelia:4.39.19 | ✅ | |
| home-assistant:2026.4.3 | ✅ | |
| gatus:v5.35.0 | ✅ | |
| mailserver/docker-mailserver:15.1.0 | ✅ | |
| kyverno:v1.18.1 | ✅ | |
| registry:2.8.3 | ✅ | |
| grafana/alloy, loki, grafana | ✅ | |
| prometheus, alertmanager, node-exporter | ✅ | |
| cert-manager (all components) | ✅ | |
| haproxy-ingress:v0.16.1 | ✅ | |
| stakater/reloader:v1.4.16 | ✅ | |
| velero:v1.18.0 | ✅ | |
| tetragon:v1.7.0 | ✅ | |
| **patschi/parsedmarc:latest** | ⚠️ amd64 only | Community image, pinned by sha256. Acceptable — parsedmarc is lightweight, run on amd64 node or rebuild. |
| **drwetter/testssl.sh:3.2** | ⚠️ amd64 only | Shell-based tool, could build multi-arch. Low priority — runs weekly, schedule on amd64 node. |

**Conclusion**: 2 images are amd64-only (parsedmarc, testssl). Both are non-critical
CronJobs that can be scheduled on amd64 nodes via `nodeSelector`. All core services
are fully multi-arch.

**Context**: The cluster runs on mixed architectures — the cloud ARM node is ARM64,
bare-metal may be AMD64. Every image pull must resolve the correct platform
manifest. Additionally:
- Docker Hub has rate limits (100 pulls/6h for anonymous, 200 for free accounts)
- Image pulls from the internet are a single point of failure
- Deploying to both architectures without a cache means double bandwidth

**Decision**: Deploy a container registry as a pull-through cache backed by
Garage S3 storage.

**Architecture**:
```
Pod pulls image
     │
     ▼
K3S registries.yaml → local registry (pull-through cache)
                            │
                            ├── cache hit → serve from Garage S3
                            │
                            └── cache miss → pull from upstream (Docker Hub, ghcr.io)
                                             store in Garage S3
                                             serve to pod
```

**Implementation**:
1. Deploy [Distribution](https://github.com/distribution/distribution) registry
   in K3S with Garage S3 as storage backend
2. Configure as pull-through cache for Docker Hub, ghcr.io, quay.io
3. Configure K3S `registries.yaml` on all nodes via Ansible:
   ```yaml
   mirrors:
     docker.io:
       endpoint:
         - "https://registry.internal.cluster"
     ghcr.io:
       endpoint:
         - "https://registry.internal.cluster"
   configs:
     "registry.internal.cluster":
       tls:
         ca_file: "/etc/rancher/k3s/registry-ca.crt"
   ```
4. The `k3s` Ansible role already supports `k3s_installation_registries` —
   wire it up with the registry endpoint
5. Validate all pinned images have multi-arch manifests (ARM64 + AMD64)

**Bootstrapping — avoiding circular dependency**:
Garage runs in K3S. The registry runs in K3S. K3S needs the registry to
pull images. But the registry needs Garage. Circular dependency.

Solution: **two-phase bootstrap**.

Phase 1 (initial deploy): `registries.yaml` is NOT configured. K3S pulls
infrastructure images (Cilium, CoreDNS, OpenEBS, Garage, registry) directly
from upstream registries. This is the normal first-deploy behavior.

Phase 2 (post-bootstrap): Once Garage and the registry are running, Ansible
updates `registries.yaml` on all nodes to point at the local cache, then
restarts K3S. All subsequent pulls go through the cache.

```
Phase 1:  02-k3s.yml → 05-storage.yml (Garage + registry deploy)
          K3S pulls from upstream, no registries.yaml mirrors

Phase 2:  05-storage.yml (configure registries.yaml, restart K3S)
          All future pulls go through local cache
```

The `k3s_registry` role should have a `bootstrap` tag that deploys the
registry without configuring mirrors, and a `configure` tag that wires up
`registries.yaml` after the registry is healthy.

**Benefits**:
- One pull from upstream serves both ARM64 and AMD64 nodes
- Survives Docker Hub outages and rate limits
- Faster deploys (local cache)
- Garage provides geo-replicated storage (relay node + bare-metal)
- No circular dependency — clean bootstrap path

**Related**: ADR-012 (Garage), ADR-010 (multi-arch cloud ARM node)
