# USB Disk Storage

Decision: [ADR-035](adr/035-usb-storage.md)

## Overview

USB-attached SSD/HDD can be used as local storage for K3S workloads (Garage
S3, backups, scratch space). Disks are onboarded using the existing
`disks_lvm_management` role — no special role needed.

Key constraints:
- Mount by `/dev/disk/by-id/` (not `/dev/sdX` which changes across reboots)
- Always use `nofail` mount option (system must boot without the disk)
- SMART monitoring requires per-bridge USB chipset type (`-d sat`, etc.)
- Storage is node-local (`ReadWriteOnce`) — not HA

## Identifying a USB disk

```bash
# List all block devices
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,MODEL,SERIAL

# Find the stable by-id path (look for usb- prefix)
ls -la /dev/disk/by-id/ | grep usb

# Get UUID and filesystem info
blkid /dev/disk/by-id/usb-Samsung_T7_S7A1NJ0X12345-0:0

# Detailed device info
udevadm info --query=all /dev/disk/by-id/usb-Samsung_T7_S7A1NJ0X12345-0:0
```

The `by_id` value from `ls /dev/disk/by-id/` is the stable identifier to use
in Ansible inventory. It encodes vendor, model, and serial — it survives
reboots, port changes, and kernel upgrades.

## Ansible configuration

Declare in `host_vars/<hostname>.yml` using existing variables:

```yaml
# Partition a blank disk (skip if already partitioned)
disk_partitions_to_create:
  - device: /dev/disk/by-id/usb-Samsung_T7_S7A1NJ0X12345-0:0
    part_number: 1
    name: "garage_data"

# Format + mount (btrfs for checksumming + zstd compression)
filesystems_to_create:
  - dev: /dev/disk/by-id/usb-Samsung_T7_S7A1NJ0X12345-0:0-part1
    fstype: btrfs
    opts: "-f -L garage-data"
    mount_path: /mnt/disks/garage-data
    mount_path_mode: "0755"
    mount_opts: "defaults,noatime,nofail,compress=zstd:3,autodefrag"

# SMART monitoring
usb_storage_smart_enabled: true
usb_storage_smart_devices:
  - name: garage-data
    by_id: usb-Samsung_T7_S7A1NJ0X12345-0:0
    smartctl_device_type: sat

# Filesystem space alerts (optional, via monit)
monit_filesystems:
  - { mnt: "/mnt/disks/garage-data", usage_alerts: ["85%", "95%"] }
```

Then run `just configure` — the existing `disks_lvm_management` role handles
partitioning, formatting, and fstab mount. The `system_packages` role
installs `smartmontools` and deploys check scripts. The `monit_usb_storage`
role adds periodic SMART health alerts.

## SMART compatibility

USB-attached disks need a bridge-specific `-d` type for `smartctl`. The type
depends on the USB-to-SATA/NVMe bridge chipset, not the disk itself.

### Finding the right type

```bash
# Try the most common type first
smartctl -d sat -i /dev/disk/by-id/usb-Samsung_T7_...
# If that fails, try auto-detection
smartctl -d auto -i /dev/disk/by-id/usb-Samsung_T7_...
# Check dmesg for the bridge chipset
dmesg | grep -i 'usb.*storage\|uas'
```

### Common USB bridge types

| Bridge chipset | `smartctl_device_type` | Common enclosures |
|----------------|------------------------|-------------------|
| Generic SAT | `sat` | Most USB-SATA adapters, Samsung T5/T7 |
| Realtek RTL9210 | `sntrealtek` | Many NVMe-to-USB enclosures |
| JMicron JMS578 | `sat` | Budget SATA enclosures |
| JMicron JMS583 | `jmb39x-q,0` | NVMe enclosures |
| ASMedia ASM2362 | `sat` | Some NVMe enclosures |
| VIA VL716 | `sat` | Older enclosures |

Full reference: https://www.smartmontools.org/wiki/USB

### Manual SMART check

```bash
# Health status (pass/fail)
smartctl -d sat -H /dev/disk/by-id/usb-...

# Full info (model, serial, firmware, temp, hours, errors)
smartctl -d sat -a /dev/disk/by-id/usb-...

# Short self-test (runs in background, ~2 minutes)
smartctl -d sat -t short /dev/disk/by-id/usb-...
smartctl -d sat -l selftest /dev/disk/by-id/usb-...
```

## K3S / OpenEBS integration

The USB mount path can be consumed by K3S workloads in three ways:

### Pattern A — Replace OpenEBS base path

Mount the USB disk at `/var/openebs/local` (or `/var/openebs`). All existing
PVCs using the `openebs-hostpath` StorageClass automatically use it.

```yaml
filesystems_to_create:
  - dev: /dev/disk/by-id/usb-...-part1
    fstype: xfs  # XFS for database PVs (PostgreSQL, etcd) — low fragmentation, no COW overhead
    mount_path: /var/openebs
    mount_opts: "defaults,noatime,nofail"
```

### Pattern B — Dedicated StorageClass

Mount at a custom path and add a second OpenEBS StorageClass in Kluctl:

```yaml
# kluctl/storage/openebs/usb-storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: openebs-usb
provisioner: openebs.io/local
parameters:
  basePath: /mnt/disks/garage-data
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
```

Workloads select it via `storageClassName: openebs-usb`.

### Pattern C — Direct hostPath

For single-workload disks, use `hostPath` directly in the pod spec:

```yaml
volumes:
  - name: data
    hostPath:
      path: /mnt/disks/garage-data
      type: Directory
```

All patterns are node-local. Workloads must use `nodeAffinity` or be
single-replica to ensure they schedule on the right node.

## Post-mount validation

```bash
# Verify the mount
findmnt /mnt/disks/garage-data

# Check filesystem details
lsblk -f

# Write test
touch /mnt/disks/garage-data/.mount-test && rm /mnt/disks/garage-data/.mount-test

# Verify fstab entry
grep garage-data /etc/fstab
```

## Troubleshooting

**Disk not found at boot**: `nofail` prevents boot hang. Check `dmesg | grep usb`
and `lsblk`. The USB cable or port may have changed — `by-id` paths are
port-independent, but the disk must be physically connected.

**SMART reports "unsupported"**: Try different `-d` types (`sat`, `auto`,
`sntrealtek`). Some cheap enclosures do not pass SMART commands at all.

**UUID changed after format**: This is expected — `mkfs` generates a new UUID.
The `disks_lvm_management` role uses device paths (not UUID) in fstab, so
this is transparent.

**Slow performance**: Check if the disk is connected via USB 2.0 instead of
3.0 (`dmesg | grep -i 'new.*speed'`). Also check `noatime` is set in mount
options to reduce unnecessary writes.
