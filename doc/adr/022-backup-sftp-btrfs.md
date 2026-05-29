# ADR-022: Backup strategy — SFTP + btrfs + K3S etcd snapshots

**Status**: Done

**Context**: The old setup used Duplicity (duply) pushing GPG-encrypted backups
via SFTP to a dedicated backup node. The backup node had a "frozen" copy
(daily `cp -a` snapshot) to protect against ransomware/deletion.

**Critical constraint**: Backups must work when K3S is dead.
Garage runs in K3S — if K3S is down, Garage is down. So backups go to a
dedicated backup node via SFTP, same proven pattern as before.

**Decision**: Keep SFTP to the backup node. Add K3S-native etcd snapshots.
Use btrfs on the backup node for snapshots/checksums/compression.

**Architecture**:
```
K3S node (bare-metal)                    Backup node (SFTP, no K3S)
┌─────────────────────────┐              ┌──────────────────────┐
│                         │              │ btrfs (zstd)         │
│ K3S auto-snapshots      │              │                      │
│ every 6h → local dir    │              │ /home/backups/       │
│                         │              │   ├── node-a/        │
│ kopia backup (daily):  │── SFTP ─────►│   │   ├── latest     │
│   /var/lib/rancher/k3s/ │              │   │   └── snapshots/ │
│   /var/openebs/local/   │              │   └── node-b/        │
│   /home/                │              │                      │
│   /etc/                 │              │ btrfs snapshots:     │
│                         │              │   hourly (keep 24)   │
└─────────────────────────┘              │   daily (keep 7)     │
                                         │   weekly (keep 4)    │
                                         │                      │
                                         │ Cold: btrfs send →   │
                                         │   external drive     │
                                         └──────────────────────┘
```

**K3S built-in etcd snapshots**:
```yaml
# Added to k3s_installation_server config
etcd-snapshot-schedule-cron: "0 */6 * * *"   # every 6 hours
etcd-snapshot-retention: 5                     # keep 5 local snapshots
etcd-snapshot-dir: /var/lib/rancher/k3s/server/db/snapshots
```

Kopia picks up these snapshots as part of its daily backup sweep.

**What gets backed up**:

| What | Location | Tool | Destination |
|------|----------|------|-------------|
| K3S datastore | `/var/lib/rancher/k3s/server/db/` | K3S auto-snapshot + kopia | Backup node (SFTP) |
| PV data | `/var/openebs/local/` | kopia | Backup node (SFTP) |
| Host config | `/home/`, `/etc/` | kopia | Backup node (SFTP) |
| DB dumps | MariaDB → `/var/backups/mariadb/` | mariadb-dump + kopia | Backup node (SFTP) |
| Kluctl manifests | git repo | git push | GitHub |
| Vault secrets + certs | `secret_vars/`, `certs/` | `just push` | Backup location |

**What does NOT need backing up** (rebuildable):
- K3S binaries (reinstall via Ansible)
- Container images (re-pull from registry/cache)
- Loki logs (ephemeral, retention policy handles lifecycle)
- Garage data in K3S (registry cache is rebuildable)

**Why btrfs on the backup node**:
- **zstd compression**: saves 30-50% disk on backup data
- **Checksumming**: detects bit rot (critical for backups)
- **Snapshots**: replaces old `backup_frozen_directory` cron. Instant, atomic,
  read-only — ransomware can't modify them without root on the backup node
- **send/receive**: efficient cold backup to external drive
- Single disk or RAID1 only (avoid btrfs RAID5/6 — write hole bug)

**Kopia replaces Duplicity**:

| Criteria | Duplicity (current) | Kopia (new) |
|----------|-------------------|-------------|
| SFTP | pexpect workaround | Native |
| Deduplication | No | Yes (content-defined chunking) |
| Compression | gzip | zstd (default, much better ratio) |
| Encryption | GPG (complex key mgmt) | AES-256 or ChaCha20 (password-based) |
| Integrity check | Basic `verify` | `snapshot verify --verify-files-percent 100 --force-hash` (re-checksums actual data blobs) |
| Email notifications | No | **Built-in** (`kopia notification profile configure email`) |
| Snapshot reports | No | **Built-in** (v0.23.0 templates: what was backed up, errors, duration) |

**Monitoring integration** (KISS — no server mode):
- Kopia systemd timer `OnFailure=` unit: sends email + ntfy on backup failure
- Alloy textfile collector: exposes `kopia_last_backup_timestamp_seconds` metric
- Prometheus alerting rule: fires if no successful backup in 24h
- Alertmanager routes alert to email + ntfy

**Verification schedule** (on backup node):
```
daily:   kopia snapshot verify --verify-files-percent 5
weekly:  kopia snapshot verify --verify-files-percent 100 --force-hash
         (re-downloads and re-checksums all data blobs — detects bit rot)
```

Email notification on any verification failure. Gatus alerts if
verification hasn't run in the expected window.

**Disaster recovery procedure**:
```sh
# 1. Provision fresh node
just provision --user=root
just configure

# 2. Install K3S and restore datastore from snapshot
scp backup-store:/home/backups/node-a/k3s-snapshot.db /tmp/
k3s server --cluster-reset \
  --cluster-reset-restore-path=/tmp/k3s-snapshot.db

# 3. Redeploy workloads (manifests in git)
just deploy

# 4. Restore PV data (application databases, mail, etc.)
kopia restore --snapshot-id <latest> /var/openebs/local/
```

The key: K3S cluster state (etcd snapshot) + Kluctl manifests (git) = rebuild
the cluster from scratch. The only irreplaceable data is PV content (databases,
mail storage). That's what kopia → SFTP protects.

**Implementation**:
1. [x] Add etcd snapshot flags to `k3s_installation_server` config (T26)
2. [x] btrfs snapshots in `backup_storage` role (replaces `btrfs_backup`)
3. [x] Create role `kopia` — installs Kopia, configures SFTP repository,
   snapshot policies, verification schedule, email notifications
4. ~~Run Kopia server on backup node~~ → dropped (KISS: client-only mode)
5. [x] Update `backup_storage` role: btrfs snapshots replace `backup_frozen_directory`
6. [x] Update backup includes: `/var/lib/rancher/k3s/server/db/`,
   `/var/openebs/local/`, `/home/`, `/etc/`
7. [ ] Alerting: email/ntfy on backup failure + Prometheus alert if no backup in X hours

**Monitoring (no server mode — KISS)**:
- Kopia runs as systemd timer on each node (client-only, no central daemon)
- On failure: `OnFailure=` systemd unit sends email + ntfy notification
- Each Kopia timer exposes a textfile metric (via Alloy `node_exporter` integration):
  `/var/lib/prometheus/node-exporter/kopia_last_backup.prom`
  ```
  kopia_last_backup_timestamp_seconds{node="ctrl"} 1716710400
  kopia_last_backup_success{node="ctrl"} 1
  ```
- Prometheus alerting rule: `kopia_last_backup_timestamp_seconds < (time() - 86400)`
  → alert if no successful backup in 24h
- No KopiaUI, no Gatus check needed — Prometheus/Alertmanager handles it

**Backup node in inventory** (same pattern as old `backup_storage`):
```yaml
backup_nodes:
  hosts:
    backup-store:

all_logging:
  hosts:
    backup-store:  # Alloy (systemd) ships logs to Loki
```

**Security**:
- Backup node is not a K3S member — no kubelet, no secrets exposure
- SFTP access restricted by IP + SSH key (existing `backup_storage` role)
- Btrfs read-only snapshots are immutable
- Cold backup on external media = air-gapped recovery
- Backup node accessible only via Headscale mesh (zero public ports)
