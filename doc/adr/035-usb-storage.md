# ADR-035: USB disk storage for local K3S workloads

**Status**: Done

**Date**: 2026-05-26

**Context**: Homelab and lightweight infrastructure nodes often use USB-attached
SSD/HDD as additional local storage for K3S workloads (Garage S3, backups,
scratch). These disks need stable mounting across reboots despite Linux device
name changes (`/dev/sdX` is not stable), and SMART health monitoring must
account for USB bridge chipset quirks.

**Decision**: Reuse the existing `disks_lvm_management` role for USB disk
partitioning, formatting, and mounting. No new Ansible role for disk
management — USB disks are declared via the same `filesystems_to_create`
variable in host_vars, using `/dev/disk/by-id/` paths for stable device
identification and `nofail` mount option so the system boots without the disk.

SMART monitoring is handled by:
- `smartmontools` package installed conditionally via `system_packages`
- Per-device check scripts deployed to `/usr/local/bin/`
- `monit_usb_storage` companion role for periodic health alerts

The mounted paths are consumed by K3S/OpenEBS at a higher layer — the disk
role has no coupling to Kubernetes.

**Consequences**:
- USB storage is node-local (`ReadWriteOnce`). Workloads must tolerate this
  (single replica, nodeAffinity, or application-level replication).
- SMART monitoring requires knowing the USB bridge type (`-d sat`,
  `-d sntrealtek`) — see `doc/usb-storage.md` for the compatibility table.
- Formatting is gated behind the existing `force` flag in
  `filesystems_to_create` — no accidental wipe risk.
- `nofail` mount option means a missing USB disk does not block boot, but
  workloads depending on it will fail until the disk is reconnected.
