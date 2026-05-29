# ADR-003: K3S storage — OpenEBS hostpath

**Status**: Implemented

**Context**: K3S includes local-path-provisioner by default but it is basic
(no snapshots, no metrics). A more robust storage provider is needed.

**Options evaluated**:

| Solution | RAM overhead | IOPS | Replication | Snapshots | Complexity |
|----------|-------------|------|-------------|-----------|------------|
| local-path (K3S built-in) | ~0 | Native | No | No | Zero |
| **OpenEBS hostpath** | ~180 MB | Near-native | No | Depends | Low |
| Longhorn | ~1.5 GB | ~19K | Yes | Yes | Low |
| OpenEBS Mayastor | Moderate | ~28K | Yes | Yes | Medium |
| Rook-Ceph | ~2+ GB | Variable | Yes | Yes | High |

**Decision**: OpenEBS in hostpath provisioner mode (single-node).
Migrate to Mayastor when multi-node replication is needed.

**Justification**:
- On a 2-node cluster with limited resources (cloud free tier = 1 GB RAM),
  Longhorn at 1.5 GB overhead is disqualified.
- Stateful applications (PostgreSQL, MariaDB) handle their own replication.
  Adding storage-level replication is redundant and doubles latency.
- OpenEBS hostpath gives near-native performance with proper automation
  (provisioning, metrics, lifecycle) for ~180 MB of RAM.
- If storage replication is needed later, we can migrate to Mayastor
  without changing existing PVCs.

**Why OpenEBS over Longhorn for this architecture**:
- Workloads manage their own replication (MariaDB operator, Garage multi-node,
  Loki via S3) — storage-level replication is redundant overhead.
- OpenEBS LocalPV has zero datapath overhead (no controller per volume, no
  in-memory index). Longhorn maintains 256 MB/TB of index RAM per replica.
- OpenEBS is more modular: LocalPV now, Mayastor later, same operator.
- Lower resource consumption for equivalent local storage functionality.

**Multi-node evolution path (Mayastor)**:

When moving to 2+ nodes with replication needs:

| Phase | Storage | Use case |
|-------|---------|----------|
| Current (single-node) | OpenEBS hostpath | All workloads — local SSD, near-native IOPS |
| Future (multi-node) | OpenEBS Mayastor | Volumes needing HA (etcd, DBs without app-level replication) |
| Future (multi-node) | OpenEBS hostpath (kept) | Workloads with app-level replication (Garage, Loki S3) |

Migration to Mayastor is non-disruptive: existing hostpath PVCs stay as-is,
new PVCs can select `openebs-mayastor` StorageClass. Both coexist under the
same OpenEBS operator.

**Constraints for Mayastor**:
- Incompatible with NDM/cStor (not deployed, so no concern)
- Requires dedicated NVMe or raw block devices per node
- Needs `hugepages-2Mi` kernel support (Debian 13 Trixie: OK)

**Disk layout** (production):
On production hosts, K3S and OpenEBS data must be on a dedicated partition,
separated from the OS.

Filesystem selection:
- **XFS** for `/var/lib/rancher` and `/var/openebs` — containerd overlayfs2
  requires XFS (official recommendation), databases benefit from low
  fragmentation and no COW overhead.
- **btrfs** for Garage object storage (`/mnt/disks/garage-data`) — checksumming
  detects bit rot, zstd compression saves ~30% space, COW is fine for
  write-once S3 objects. Dedicated disk (USB SSD or second internal disk).
- Do NOT use btrfs for `/var/lib/rancher` (containerd "btrfs" driver is less
  tested) or `/var/openebs` (COW fragments database workloads).

| Mount | Filesystem | Location | Content |
|-------|-----------|----------|---------|
| `/var/lib/rancher` | XFS | LV 40% of data disk | K3S (etcd, containerd images, manifests) |
| `/var/openebs` | XFS | LV 60% of data disk | OpenEBS PVs (databases, mail) |
| `/mnt/disks/garage-data` | btrfs | Dedicated disk (USB/internal) | Garage S3 objects (registry, Loki, backups) |

On dev VMs (single disk), this is skipped — root filesystem is used directly.
See `inventories/dev/host_vars/host.sample.yml` for the full configuration example.

**Implementation**:
1. ~~Create Kluctl component `storage/openebs/` deploying the OpenEBS Helm chart~~ ✅
2. ~~Configure `openebs-hostpath` StorageClass as default (`isDefaultClass: true`)~~ ✅
3. ~~Disable the built-in K3S local-path-provisioner (`disable: local-storage` in k3s config)~~ ✅
4. Document storage paths on each node (see disk layout above)
