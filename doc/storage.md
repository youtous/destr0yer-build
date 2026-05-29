# Storage

Decisions: [ADR-003](adr/003-openebs-hostpath.md) (OpenEBS),
[ADR-012](adr/012-object-storage-garage.md) (Garage S3),
[ADR-026](adr/026-velero-backup.md) (Velero)

## Overview

Three-tier storage: OpenEBS provides local persistent volumes, Garage provides
S3-compatible object storage, and Velero orchestrates Kubernetes-native backups
to Garage.

```
Workloads (Authelia, HA, Mail, Grafana, …)
      │ PVC requests
      ▼
OpenEBS hostpath → /var/openebs/local
      │
      │ Garage PVC (20Gi)          Velero node-agent (Kopia)
      ▼                            ▼
   Garage S3 ◄── S3 PUT/GET ── Velero
   (bucket: velero-backups)
      ▲
      │ S3 (Seafile buckets, future Loki/registry)
```

Deploy order: `openebs` → barrier → `garage` + `registry` + `velero`
(defined in `kluctl/storage/deployment.yaml`).

## OpenEBS hostpath

**Kluctl Helm**: `kluctl/storage/openebs/`, chart `localpv-provisioner` v4.4.0.

- **StorageClass**: `openebs-hostpath` (created by Helm, not a raw manifest)
- **Base path**: `/var/openebs/local`
- **Reclaim policy**: `Delete`
- **Default StorageClass** — `openebs-hostpath` (K3S `local-path` disabled)
- No replication, no CSI snapshots (lightweight for 2-node dev)

Used by: Garage, registry, Authelia, Home Assistant, mailserver, Grafana,
Prometheus, Seafile, Mosquitto, Zigbee2MQTT, parsedmarc.

## Garage S3

**Kluctl raw manifests**: `kluctl/storage/garage/`.

- **Image**: `dxflrs/garage:v1.1.0`, StatefulSet with 1 replica (dev)
- **Storage**: 20Gi PVC on `openebs-hostpath`, LMDB metadata + block storage
- **Replication**: factor 1 (dev); prod targets multi-zone layout via
  `garage layout assign`
- **S3 API**: port 3900, region `garage`, path-style
- **Admin API**: port 3903 (token from SOPS)
- **Admin**: via `just garage <command>` (no WebUI, image is distroless)

Bucket creation is manual via the `garage` CLI or admin API (not automated in
repo). Current consumers: Velero (`velero-backups`), Seafile (commits/fs/blocks).
Planned: Loki archival, registry backend.

## Velero

**Kluctl Helm**: `kluctl/storage/velero/`, chart `velero` v12.0.1.

- **Volume mode**: `defaultVolumesToFsBackup: true` — Kopia file-level backup
  via node-agent (required because OpenEBS has no CSI snapshots)
- **Backend**: S3-compatible (Garage), bucket `velero-backups`, path-style
- **Schedule**: `daily-backup` at `0 3 * * *`, TTL 168h (7 days)
- **Reporting**: CronJob `velero-backup-report` at `0 7 * * *` — emails admin
  on failure/partial, or weekly summary on Monday

**Two-tier backup model**:
- Velero → Garage S3: operational restore (namespace-level, accidental deletion)
- Kopia → SFTP → btrfs backup node ([ADR-022](adr/022-backup-sftp-btrfs.md)):
  disaster recovery when cluster/Garage are both down

## Operations

```sh
just deploy-only storage/openebs  # redeploy OpenEBS
just deploy-only storage/garage   # redeploy Garage
just deploy-only storage/velero   # redeploy Velero
```
