# ADR-023: Disaster recovery plan

**Status**: Decided

**Scenarios and recovery**:

| Scenario | Impact | Recovery | RTO | RPO |
|----------|--------|----------|-----|-----|
| Pod crash | Service briefly unavailable | K8S auto-restart | Seconds | 0 |
| Worker node failure | Workloads rescheduled | K8S reschedules pods, restore PV from backup | Minutes | Last backup |
| Control plane failure | Cluster inoperable | Restore etcd snapshot, rejoin workers | 30 min | 6h (snapshot) |
| Full cluster loss | Everything down | Rebuild from Ansible + Kluctl + git, restore from backup node | 2-4h | Last backup |
| Backup node failure | No impact on running services | Replace hardware, restore from cold backup (btrfs send) | Days | Last cold backup |
| Relay node failure | Public access lost, internal works via mesh | Re-provision relay, update DNS | 1h | 0 (no data on relay) |
| Headscale failure | New mesh joins fail, existing tunnels persist | Restore from backup or redeploy | 30 min | 0 |
| DNS provider outage | Public name resolution fails | Wait or switch to backup DNS | Variable | N/A |
| Cert expiry | TLS errors on services | cert-manager auto-renews; if CA lost, re-issue from backup | Minutes | N/A |

**Full cluster rebuild procedure** (worst case — all nodes lost):

```
Phase 1 — Infrastructure (Ansible, ~30 min)
  1. Provision fresh bare-metal nodes
     just provision --user=root
  2. Configure OS, SSH, firewall, WireGuard, Alloy, node-exporter
     just configure
  3. Install K3S + Cilium bootstrap
     just k3s

Phase 2 — Restore cluster state (~15 min)
  4. Copy etcd snapshot from backup node
     scp backup-store:/home/backups/node-a/k3s-snapshots/latest /tmp/
  5. Wipe pre-existing K3S server state (avoids encryption key mismatch)
     systemctl stop k3s
     rm -rf /var/lib/rancher/k3s/server/db /var/lib/rancher/k3s/server/cred
  6. Restore K3S with snapshot
     k3s server --cluster-reset \
       --cluster-reset-restore-path=/tmp/snapshot.db
  7. Verify cluster is healthy
     kubectl get nodes && kubectl get pods -A

Phase 3 — Redeploy workloads (Kluctl, ~15 min)
  7. Deploy all K8S components from git
     just deploy
  8. Verify services are up
     just smoke-test (or manual kubectl checks)

Phase 4 — Restore application data (~30 min-2h)
  9. Restore PV data from backup node
     kopia restore --snapshot-id <latest> /var/openebs/local/
  10. Restart affected pods to pick up restored data
      kubectl rollout restart deployment -n <namespace>
  11. Verify application data integrity
```

**What's rebuildable from git (no backup needed)**:
- K3S binaries (Ansible reinstalls)
- All K8S manifests and Helm values (Kluctl in git)
- Container images (re-pull from upstream or registry cache)
- Loki logs (ephemeral, retention policy)
- Ansible roles and config (git)

**What requires backup restoration**:
- etcd snapshot (cluster state: namespaces, secrets, RBAC, CRDs)
- PV data: databases (MariaDB, PostgreSQL), mail storage, Grafana dashboards
- Host data: `/home`, SSH keys, WireGuard keys (in Ansible Vault)
- TLS root CAs and private keys (in Ansible Vault + `just push/pull`)

**K3S secrets-encryption and key management**:

K3S stores the AES-CBC encryption key in
`/var/lib/rancher/k3s/server/cred/encryption-config.json`.
This key is **included in etcd snapshots** — a snapshot restore brings back
both the encrypted data and the matching key.

| Scenario | Risk | Mitigation |
|----------|------|------------|
| Restore from etcd snapshot | None — key and data are bundled in the snapshot | Standard restore procedure (Phase 2 step 5) |
| Total node loss without snapshot | Secrets in etcd are lost | All K8S secrets are recreated by `just deploy` from SOPS/Vault (source of truth is git, not etcd) |
| Restore snapshot on node with pre-existing key | Key mismatch — secrets unreadable | **Delete `/var/lib/rancher/k3s/server/` before restoring** to avoid conflict |
| Encryption key rotation needed | Old secrets remain encrypted with old key | `k3s secrets-encrypt rotate-keys && k3s secrets-encrypt reencrypt` |

Critical rule: before restoring an etcd snapshot on an existing node, always
wipe the K3S server state first:
```
systemctl stop k3s
rm -rf /var/lib/rancher/k3s/server/db /var/lib/rancher/k3s/server/cred
k3s server --cluster-reset --cluster-reset-restore-path=/tmp/snapshot.db
```

The encryption key is **not** a single point of failure: all application secrets
are reconstructible from git + SOPS + Ansible Vault via `just deploy`.

**Testing DR**:
- Monthly: restore etcd snapshot on Vagrant, verify cluster comes up
- Quarterly: full rebuild from scratch on Vagrant (all 4 phases)
- Verify backup integrity: `kopia snapshot verify` in cron
