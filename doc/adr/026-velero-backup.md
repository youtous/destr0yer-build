# ADR-026: Velero — K8S-native backup with Kopia backend

**Status**: Done

**Context**: ADR-022 covers host-level backups (Kopia → SFTP → backup node).
But K8S-native resources (namespaces, deployments, secrets, CRDs, PVCs) benefit
from a K8S-aware backup tool that understands the object graph — not just files.

Velero (CNCF, v1.18) provides K8S-native backup/restore/migration. Since v1.10,
Velero uses **Kopia as its file system backup backend** (Restic is deprecated).
This aligns perfectly with our Kopia choice.

**Decision**: Deploy Velero with Kopia uploader for K8S resource + PV backup.
Backup target: Garage S3 (in-cluster). For DR, Kopia host-level backup
(ADR-022) also captures etcd snapshots and PV files via SFTP.

**Two complementary backup paths**:

```
Path 1 — Velero (K8S-native, in-cluster)
  Velero → Kopia uploader → Garage S3
  What: K8S resources + PV data (namespace-level granularity)
  Restore: velero restore (recreates K8S objects + PV data)
  Use case: accidental deletion, namespace restore, cluster migration

Path 2 — Kopia host-level (ADR-022, external)
  Kopia → SFTP → backup node (btrfs)
  What: etcd snapshots, PV files, host config
  Restore: full cluster rebuild from scratch
  Use case: total cluster loss, disk failure
```

Path 1 is for operational recovery (oops, deleted a namespace).
Path 2 is for disaster recovery (cluster is gone, rebuild from zero).

**Why both**: Velero stores backups in Garage (in K3S). If K3S is dead,
Velero backups are unreachable. Path 2 (Kopia → SFTP) is the safety net
that works when everything else is broken.

**Velero + OpenEBS hostpath**:
OpenEBS hostpath does NOT support CSI snapshots. Velero uses the
`node-agent` (Kopia-based) to do file-level backup of mounted PVs.
This works with any storage class including hostpath.

**Velero's role in the 3-layer strategy** (see `doc/operations.md`):

- Layer 1 (MariaDB Operator) — logical SQL dumps for transactional coherence
- **Layer 2 (Velero)** — K8S resources + config PVCs (Authelia, HA, Z2M, Mosquitto)
- Layer 3 (Kopia host-level) — DR safety net when K3S is dead

Velero FSB should **exclude** MariaDB PVCs (backed up by Operator Backup CR)
and include all config/state PVCs:

```yaml
# On MariaDB StatefulSets (exclude — dump is the correct method)
backup.velero.io/backup-volumes-excludes: data

# On Authelia, HA, Mosquitto, Z2M (include)
backup.velero.io/backup-volumes: config
```

**Schedule**:
```yaml
# Daily backup of all namespaces, 7-day retention
velero schedule create daily-backup \
  --schedule "0 3 * * *" \
  --ttl 168h \
  --default-volumes-to-fs-backup
```

**Implementation**: Deploy via Kluctl in `storage/velero/` with
`velero-plugin-for-aws` pointing at Garage S3 endpoint.
