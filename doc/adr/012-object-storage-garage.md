# ADR-012: Object storage — Garage (S3-compatible)

**Status**: Done (single-node) — multi-site replication deferred to multi-cluster rollout

**Context**: Nextcloud was used for file sync + collaboration. MinIO Community Edition
was archived in February 2026. A lightweight self-hosted S3 storage is needed for:
- Loki log archival (S3 backend)
- Backup storage (kopia destination)
- General file storage (replacing Nextcloud's file component)
- Future: media, static assets

**Garage** (by Deuxfleurs):
- Written in Rust, ~50 MB RAM, extremely lightweight
- S3-compatible API
- Built for geo-distributed self-hosting (perfect for local + cloud relay)
- Replicates data across nodes automatically
- Active project (latest release April 2026, v2.x)
- Single-binary, `garage server --single-node` for simple setups

**Garage vs Nextcloud** — different purposes:

| | Garage | Nextcloud |
|---|---|---|
| File storage | S3 API | WebDAV + web UI |
| Calendar/Contacts | No | Yes (CalDAV/CardDAV) |
| Collaboration | No | Yes (Office, Talk) |
| Web UI | No (needs a frontend) | Yes (full app) |
| RAM usage | ~50 MB | ~500 MB+ (PHP-FPM + nginx + DB) |
| Geo-replication | Built-in | Plugin (limited) |
| S3 backend for other tools | Native | No |

**Decision**: Deploy Garage as the S3 infrastructure layer. It replaces MinIO
(archived) and serves as backend for Loki, registry cache, and general storage.
Nextcloud is dropped in favor of Seafile for file sync (see ADR-032).

**Administration**: No web UI deployed — CLI/TUI preferred (less attack surface, no SPOF):
- `garage` CLI (admin API on port 3903) for bucket/key management
- `aws` CLI for S3 operations (ls, cp, sync) — Alpine-based images preferred
- `s3cmd` for scripted operations
- `just garage <command>` for ad-hoc admin (execs into garage-0 pod)

**Metrics** (exposed by Garage, scraped by Prometheus):
- `garage_api_request_duration_seconds` — S3 API latency per operation
- `garage_api_request_total` — request count by method/status
- `garage_block_bytes_total` — total stored bytes across all nodes
- `garage_bucket_objects_total` — object count per bucket
- `garage_replication_queue_length` — replication lag (alerts if >0 sustained)
- `garage_rpc_request_duration_seconds` — inter-node RPC health

A Grafana dashboard sourced from these metrics provides operational visibility without a dedicated web UI.

**Sensitive data and replication**:
Garage will store sensitive data (personal files, encrypted backups, mail
attachments). It must be replicated across 2 physical sites for redundancy.

Garage's replication is built-in — configure a layout with 2+ zones:
```toml
# garage.toml
[replication]
mode = "2"  # replicate each block to 2 nodes

# Layout: assign nodes to zones (= physical sites)
# garage layout assign <node-id> -z site-a -c 1
# garage layout assign <node-id> -z site-b -c 1
```

Both Garage nodes run inside K3S (on bare-metal at site-a and site-b).
Garage handles cross-site replication over the `wg-infra-int` plane automatically.
If one site is down, the other serves all data.

Note: Garage in K3S means if K3S is down, Garage is down. For backups
specifically, Kopia pushes to the backup node via SFTP (ADR-022), not Garage.
Garage is for live data (files, registry cache, Loki archival), not the
backup-of-last-resort.

**Cross-site networking for Garage replication**:

Garage pods run in pod network (10.42.x.x) but must reach the remote
Garage node on the `wg-infra-int` plane (10.99.100.x) for RPC replication
(port 3901). The recommended K8s approach:

```
Garage pod (10.42.x.x) → pod gateway → host kernel → wg-infra-int → remote site
```

- **No `hostNetwork`** — Garage is an application, not infra. hostNetwork
  is an anti-pattern for apps (breaks network isolation).
- **Kernel routing** — the pod's default gateway is the host. The host has
  the `wg-infra-int` interface with a route to `10.99.100.0/24`. Traffic
  flows naturally through the WireGuard tunnel without any K8s-side changes.
- **Cilium NetworkPolicy** — a `toCIDR` rule scoped to the `wg-infra-int`
  subnet and Garage RPC port controls the egress:

```yaml
# CiliumNetworkPolicy for cross-site Garage replication
egress:
  - toCIDR:
      - "10.99.100.0/24"   # wg-infra-int subnet (inter-cluster mesh)
    toPorts:
      - ports:
          - port: "3901"   # Garage RPC
            protocol: TCP
```

Why `toCIDR` and not `toEntities: host`: `toCIDR` targets exactly the
inter-cluster WG subnet. `toEntities: host` would allow all traffic to
the host (too broad). Why not Cilium Cluster Mesh: ADR-010 explicitly
rejected cross-cluster K8s networking — WireGuard PTP is simpler and
independent of K8s.

**Implementation**:
1. Create Kluctl component `storage/garage/` deploying Garage in K3S
2. Configure 2-zone layout across bare-metal sites
3. Use Garage as S3 backend for Loki retention (ADR-004)
4. Use Garage as S3 backend for registry pull-through cache (ADR-015)
5. Evaluate lightweight S3 frontends for file browsing (behind Authelia)
6. When multi-zone is enabled: add `toCIDR` NetworkPolicy for Garage
   RPC egress to WireGuard mesh (see above)
