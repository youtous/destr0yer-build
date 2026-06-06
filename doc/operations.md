# Operations Guide

Day-to-day operational procedures for the K3S cluster.

## First deployment (fresh cluster)

```sh
# 1. Provision hosts (create users, SSH hardening, base packages)
just provision

# 2. Configure hosts (apt, firewall, WireGuard, Alloy, Postfix relay, fail2ban)
#    CrowdSec bouncer is skipped automatically (no API key yet)
just configure

# 3. Deploy K3S + Cilium + CoreDNS
just k3s

# 4. Deploy all K8S components (cert-manager, Kyverno, CrowdSec LAPI, storage, apps)
just deploy

# 5. Provision Garage S3 (layout + buckets + keys)
#    First assign the node role and apply layout:
just garage status                          # note the node ID
just garage layout assign -z dc1 -c 20G <NODE_ID>   # -c = capacity (match PVC size)
just garage layout apply --version 1
#    PREFIX = s3_bucket_prefix from target (includes trailing dash!)
#    Example: cluster_domain=k8s.home → PREFIX="k8s-home-"
#    Verify: just render, then grep s3_bucket_prefix in rendered output
#    Create keys and buckets:
just garage key create    ${PREFIX}velero
just garage bucket create ${PREFIX}velero-backups
just garage bucket allow  --read --write ${PREFIX}velero-backups        --key ${PREFIX}velero

just garage key create    ${PREFIX}seafile
just garage bucket create ${PREFIX}seafile-commits
just garage bucket create ${PREFIX}seafile-fs
just garage bucket create ${PREFIX}seafile-blocks
just garage bucket create ${PREFIX}seafile-backups
just garage bucket allow  --read --write ${PREFIX}seafile-commits       --key ${PREFIX}seafile
just garage bucket allow  --read --write ${PREFIX}seafile-fs            --key ${PREFIX}seafile
just garage bucket allow  --read --write ${PREFIX}seafile-blocks        --key ${PREFIX}seafile
just garage bucket allow  --read --write ${PREFIX}seafile-backups       --key ${PREFIX}seafile

just garage key create    ${PREFIX}homeassistant
just garage bucket create ${PREFIX}homeassistant-backups
just garage bucket allow  --read --write ${PREFIX}homeassistant-backups --key ${PREFIX}homeassistant

#    Get credentials (key ID + secret) → store in SOPS targets file:
just garage key info ${PREFIX}velero
just garage key info ${PREFIX}seafile
just garage key info ${PREFIX}homeassistant
just deploy

# 6. Register CrowdSec bouncer key (see "Post-deploy: CrowdSec" section below)
#    Then re-run configure to activate the host-level bouncer:
just configure --tags crowdsec

# 7. Validate
just test-integration
just test-firewall
```

> Steps 1-4 can run with empty secrets in the vault.
> CrowdSec bouncer is safely skipped until step 6. Garage consumers
> (Velero, Seafile, Loki) will be in CrashLoopBackOff until step 5 completes.
> Full bucket/key procedure: see `kluctl/targets/secrets-reference.yaml`.

## Garage S3 administration

The Garage image is distroless (only `/garage` binary, no shell). All CLI operations
go through `just garage <command>` which runs `kubectl exec -n garage garage-0 -- /garage <command>`.

```sh
just garage status              # cluster health + node IDs
just garage layout show         # current layout
just garage bucket list         # list all buckets
just garage key list            # list all API keys
just garage bucket create X     # create bucket
just garage key create X        # create API key
just garage bucket allow --read --write X --key Y
just garage --help              # full CLI reference
```

**Adding a bucket for a new consumer:**

```sh
just garage key create <key-name>
just garage bucket create <bucket-name>
just garage bucket allow --read --write <bucket-name> --key <key-name>
# Note the key ID + secret → just sops-edit kluctl/targets/<env>.enc.yaml
just deploy
```

## Kyverno: Audit → Enforce

Dev uses `kyverno_validation_action: "Audit"` (violations are logged but not blocked).
The daily violation report CronJob sends an email with all policy violations.

**To switch to Enforce for prod:**

1. Review recent violation reports — ensure no false positives
2. Set in the prod target (`kluctl/targets/prod.yaml`):
   ```yaml
   kyverno_validation_action: "Enforce"
   ```
3. Deploy: `just deploy-only security/kyverno`
4. Monitor for unexpected blocked workloads

**Gradual rollout**: You can enforce per-policy by overriding `validationFailureAction`
directly in individual policy YAML files instead of the global variable.

## OpenEBS: Default StorageClass

`openebs-hostpath` is the default StorageClass. K3S built-in `local-path` provisioner
is disabled (`disable: local-storage` in K3S server config).

If a PVC doesn't specify `storageClassName`, it will use `openebs-hostpath`.

## cert-manager: Internal CA → Let's Encrypt

Dev uses `certmanager_issuer_type: "internal-ca"` (self-signed CA).

**To switch to Let's Encrypt for prod:**

1. Create a deSEC account at https://desec.io
2. Create a delegated zone per cluster (e.g., `zone1.dedyn.io`)
3. In Cloudflare (DNS-only, non-proxied):
   ```
   _acme-challenge.pub.<domain>  CNAME  _acme-challenge.<zone>.dedyn.io
   ```
4. Add CAA record restricting issuance to Let's Encrypt only:
   ```
   <domain>  CAA  0 issue "letsencrypt.org"
   ```
5. Add the deSEC token to the prod SOPS file:
   ```sh
   # Get token from https://desec.io/tokens
   just sops-edit kluctl/targets/prod.enc.yaml
   # Set: secrets.desec_token: "deSEC-token-here"
   ```
6. Set in prod target:
   ```yaml
   certmanager_issuer_type: "letsencrypt"
   certmanager_acme_dns_zone: "example.com"
   certmanager_desec_group_name: "acme.example.com"
   ```
7. Deploy: `just deploy-only security/cert-manager`

The ClusterIssuer name stays `cluster-issuer` — all existing Ingresses
will automatically get Let's Encrypt certs without annotation changes.

## DNS: Wildcard strategy

Use wildcard DNS for public services:
- `*.pub.example.com CNAME relay.example.com` (one record covers all services)
- One wildcard certificate per cluster covers all public Ingresses
- Internal services (`*.k8s.home`) use CoreDNS + internal CA — no public DNS

## Retention policies

| Data | Retention | Config location |
|------|-----------|----------------|
| Prometheus metrics | 180d (6 months) | `.kluctl.yaml` → `prometheus_retention` |
| Loki logs | 60d (2 months) | `.kluctl.yaml` → `loki_retention_days` |
| etcd snapshots | 10 (rolling) | K3S server config |
| Velero backups | 14 (count-based) | `.kluctl.yaml` → `velero_backup_retention_count` |
| MariaDB backups | 14 (count-based) | `.kluctl.yaml` → `mariadb_backup_retention_count` |
| HA local backups | 14 (count-based) | `.kluctl.yaml` → `ha_backup_local_retention_count` |

## Alert channels

| Channel | Use case | When |
|---------|----------|------|
| Email (SMTP notifier) | All reports (Kyverno, Velero, Tetragon, testssl, drift) | Primary — mailserver healthy |
| ntfy (push notifications) | Critical alerts when mailserver is down | Fallback — see below |

**ntfy fallback**: If the mailserver itself is down, email alerts cannot be delivered.
Deploy ntfy as a lightweight push notification service for critical infrastructure
alerts (node down, mailserver down, certificate expiry). ntfy requires no email
dependency — uses HTTP push to mobile/desktop apps.

Architecture: Gatus (or Alertmanager webhook) → ntfy → push notification.
ntfy deployment is planned as a future Kluctl component (`observability/ntfy/`).

## Drift detection

A weekly CronJob runs `kluctl diff` to detect cluster drift from the declared state
(e.g., manual `kubectl edit` changes). Results are sent via email.

Drift indicates either:
- Unauthorized manual changes → revert with `just deploy`
- Missing changes in Kluctl manifests → update source and deploy

## Kluctl deploy

### Full deploy vs targeted deploy

```sh
just deploy                              # all K8S components
just deploy-only observability/promgraf  # single component (tag: "promgraf")
just deploy-only security/kyverno        # single component (tag: "kyverno")
just diff                                # preview changes
just prune                               # remove orphaned resources
```

### How `deploy-only` works

`just deploy-only <path>` extracts the **last directory name** from the path
and passes it to kluctl as `--include-tag` (`-I`). Kluctl auto-generates tags
from deployment directory names, so `observability/promgraf` matches tag
`promgraf`.

This means the `<path>` argument is **not** a filesystem path filter — it is
used for its basename only. `deploy-only observability/promgraf` and
`deploy-only promgraf` would both resolve to tag `promgraf`.

> **Caveat**: if two unrelated components share the same directory name
> (e.g. `security/extras/` and `observability/extras/`), `deploy-only` would
> deploy both. Use unique directory names to avoid this.

### Force-apply (SSA ownership)

All deploys use `--force-apply` by default. This ensures kluctl always
reclaims field ownership via Server-Side Apply, preventing silent config
drift when fields were previously modified by `kubectl` or other tools.

See [ADR-037](adr/037-kluctl-force-apply.md) for background.

## Secrets management

Two independent secret stores:

| Store | Scope | Tool | Files |
|-------|-------|------|-------|
| Ansible Vault | Host-level (SSH keys, sudo, WireGuard, Kopia, relay) | `ansible-vault` | `inventories/<env>/group_vars/*/vault*.yml`, `inventories/<env>/host_vars/*/vault*.yml` |
| SOPS (age) | K8S-level (Authelia, Garage, SMTP notifier, mailserver, Loki) | `sops` | `kluctl/targets/<env>.enc.yaml` |

The two stores are **independent by design** — no automatic sync is needed.
Each secret is generated once and stored in the appropriate layer.

### Pre-deploy: ensure SOPS secrets are populated

Before first deploy on a new environment:

```sh
# Create SOPS secrets from reference template
cp kluctl/targets/secrets-reference.yaml kluctl/targets/<env>.enc.yaml
# Generate each value (see commands in secrets-reference.yaml), then encrypt:
sops -e -i kluctl/targets/<env>.enc.yaml
# Subsequent edits:
just sops-edit kluctl/targets/<env>.enc.yaml
```

### Post-deploy: CrowdSec bouncer key (SOPS → Ansible Vault)

After the first CrowdSec LAPI deploy, a bouncer key must be registered and
propagated to the host-level firewall bouncer (Ansible role `crowdsec_bouncer`).

> **Note:** `just configure` safely skips the bouncer role when
> `crowdsec_bouncer_api_key` is empty in the vault. Run steps below after
> the LAPI is deployed, then re-run configure.

```sh
# 1. Register bouncer in CrowdSec LAPI (on ctrl)
just kubectl exec -n security deploy/crowdsec-lapi -- cscli bouncers add firewall-bouncer -o raw
# → prints the API key

# 2. Store in SOPS
just sops-edit kluctl/targets/<env>.enc.yaml
# Set: secrets.crowdsec_bouncer_key: "<key>"

# 3. Store in Ansible Vault for the host-level bouncer
just vault-edit inventories/<env>/group_vars/all/vault.yml
# Add: crowdsec_bouncer_api_key: "<key>"

# 4. Deploy host bouncer
just configure --tags crowdsec
```

### Editing secrets

```sh
# SOPS (K8S layer)
just sops-edit kluctl/targets/<env>.enc.yaml

# Ansible Vault (host layer)
just vault-edit inventories/<env>/group_vars/all/vault.yml
```

### Secrets sync — local git fork (preferred)

The preferred method is a **local git fork** with secrets committed directly.
GitHub remote is set to read-only (fetch-only). Later, a private Forgejo instance
will serve as the self-hosted remote.

```sh
# Setup (laptop — one-time)
git remote set-url --push origin DISABLED   # GitHub = read-only (fetch only)

# Vault files are git-ignored by default. On private forks, track them:
# 1. Remove the vault lines from .gitignore
# 2. Commit vault files + unencrypted local config on the deploy/ branch
git checkout -b deploy/master
git add inventories/*/group_vars/*/vault*.yml inventories/*/host_vars/*/vault*.yml .keys/ .env
git commit -m "add vault-encrypted secrets + local config (local only)"
```

**Branch convention:** secrets live on `deploy/master` (or `deploy/<env>`), never
on `master`. This makes the boundary explicit and enables push protection rules.

**Phase 1 (current):** local-only repo, secrets on `deploy/master`. Backup via
regular filesystem backup (Time Machine, restic, etc.).

**Phase 2 (future):** self-hosted Forgejo on the cluster. Add as remote and push:
```sh
git remote add forgejo git@forgejo.k8s.home:youtous/destr0yer-build.git
git push forgejo deploy/master
```

**Why this works:**

- `vault*.yml` files are AES-256 vault-encrypted — safe in any private repo
- `kluctl/targets/*.enc.yaml` are SOPS/age-encrypted — same
- `.env` and `.keys/` (unencrypted) stay git-ignored
- Atomic (code + secrets together in one repo)
- `deploy/*` prefix = clear visual marker for secret-bearing branches

### Push protection — deploy/* branches

Three layers prevent accidental secret leaks:

**Layer 1 — Local pre-push hook** (`.git/hooks/pre-push`):

Blocks any `deploy/*` branch from being pushed to remotes other than `cold` or
`forgejo`. Installed automatically — see hook file for allowed remotes list.

```sh
# This will be BLOCKED by the hook:
git push origin deploy/master
# → "BLOCKED: deploy/* branches cannot be pushed to 'origin'"

# This works (private remote):
git push cold master:deploy/master
git push forgejo deploy/master
```

**Layer 2 — GitHub branch protection rule** (server-side):

Add a branch protection rule on GitHub to reject `deploy/*` as a second safety net.
Settings → Branches → Add rule:
- Branch name pattern: `deploy/**`
- Check "Restrict pushes" → allow nobody (or restrict to a bot account)

This ensures that even if the local hook is bypassed (new clone, hook not
installed), GitHub will refuse the push server-side.

**Layer 3 — Read-only push URL:**

`git remote set-url --push origin DISABLED` makes any `git push origin` fail
regardless of branch name. Belt-and-suspenders with the hook + GitHub rule.

## Backup strategy

Three independent backup layers, each serving a different recovery scenario:

```
Layer 1 — MariaDB Operator (logical dumps → S3)
  Coherent SQL dumps (--single-transaction) → Garage S3
  For: database point-in-time recovery, upgrades, migrations
  RPO: 24h (daily CronJob via Backup CR)

Layer 2 — Velero (K8S-native → S3)
  K8S resources + PV file-level backup (Kopia uploader) → Garage S3
  For: accidental deletion, namespace restore, cluster migration
  RPO: 24h (daily schedule)

Layer 3 — Kopia host-level (→ SFTP → backup node)
  etcd snapshots + PV files + host config → btrfs backup node
  For: total cluster loss, disk failure (works when K3S is dead)
  RPO: 24h (systemd timer)
```

### Per-application backup matrix

| Application | Critical data | Backup method | Why not volume snapshot |
|-------------|--------------|---------------|----------------------|
| **MariaDB (HA, Seafile)** | Transactional DB | Operator `Backup` CR → S3 dump | InnoDB files inconsistent if copied mid-write |
| **Authelia** | SQLite (TOTP, devices) | Velero FSB (PVC) | Low write freq, acceptable risk |
| **Home Assistant** | Config + automations | Native backup (`backup.create`) | HA knows what to include |
| **Grafana** | Dashboards, datasources | Provisioned from Git (reconstructible) | Nothing critical in DB if IaC |
| **Prometheus** | TSDB metrics | Reconstructible (re-scrapes) | 180d retention, not worth backing up |
| **Loki** | Logs | S3 backend (Garage) = durable | Object storage is the backup |
| **Seafile files** | User data | Garage S3 (commit/fs/block buckets) | Object storage is the backup |
| **Mosquitto** | Retain messages | Velero FSB (PVC) | Tiny volume, low risk |
| **Zigbee2MQTT** | Device DB + config | Velero FSB (PVC) | Tiny volume, low risk |

### What does NOT need backing up (reconstructible)

- K3S binaries (reinstall via Ansible)
- Container images (re-pull from registry/cache)
- Loki logs in filesystem mode (dev only, ephemeral)
- Garage data that is itself a cache (registry pull-through)
- Prometheus TSDB (re-scrapes fill it back)

### Backup schedules

| Tool | Schedule | Retention | Target |
|------|----------|-----------|--------|
| MariaDB Operator Backup (Seafile) | 02:00 daily | `mariadb_backup_retention_count` (default 14, count-based) | `<prefix>seafile-backups` S3 bucket |
| MariaDB Operator Backup (HA) | 03:00 daily | `mariadb_backup_retention_count` (default 14, count-based) | `<prefix>homeassistant-backups` S3 bucket |
| Velero daily | 04:00 daily | `velero_backup_retention_count` (default 14, count-based) | `<prefix>velero-backups` S3 bucket |
| HA native backup | 05:00 daily (automation) | `ha_backup_local_retention_count` (default 14, count-based) | `/config/backups/` (in PVC, captured by Velero FSB) |
| Kopia host-level | 06:00 daily | Policy-based (dedup) | Backup node via SFTP |

**Schedule distribution**: Stagger backup jobs to avoid I/O and network
contention. Keep at least 1 hour between jobs, especially when they share
the same storage backend (Garage S3) or network path (SFTP over WireGuard).
Database dumps (MariaDB) should run **before** filesystem-level backups
(Velero, Kopia) so the dump files are included in the snapshot.

### Velero annotations

Volumes to include/exclude from file-level backup:

```yaml
# Include a volume in Velero FSB (Kopia)
annotations:
  backup.velero.io/backup-volumes: config,data

# Exclude a volume (backed up by other means, e.g. MariaDB dump)
annotations:
  backup.velero.io/backup-volumes-excludes: data
```

MariaDB PVCs should be **excluded** from Velero FSB — logical dump is the
correct method. Config PVCs (Authelia, HA, Z2M, Mosquitto) should be included.

### Restore order (disaster recovery)

```
1. Provision fresh node              just provision && just configure
2. Install K3S                       just k3s
3. Restore etcd from snapshot        k3s server --cluster-reset --cluster-reset-restore-path=<snapshot>
4. Deploy all workloads              just deploy
5. Restore MariaDB databases         kubectl apply -f <restore-cr>  (or manual import from S3 dump)
6. Restore HA config                 Copy native backup into PVC, restart HA
7. Verify services                   just test-integration
```

For operational recovery (deleted namespace):
```
velero restore create --from-backup <daily-backup> --include-namespaces <ns>
```

## Cloud relay (mail + optional HTTPS)

### Architecture

```
Internet → Relay HAProxy (TCP, send-proxy-v2) → WireGuard → K3S HAProxy Ingress
  → expect-proxy (conditional) → proxy-protocol → mailserver/Dovecot
```

### Kluctl args

| Arg | Default | Effect |
|-----|---------|--------|
| `mail_relay_wg_ip` | `""` (disabled) | When set, ingress accepts PROXY protocol from this WG IP |

### Ansible roles (01-configure.yml, limit relay)

| Role | What it does |
|------|--------------|
| `iptables_firewall` | UFW + IP forwarding |
| `wireguard_meta` | WG tunnel (relay = server) |
| `cloud_relay` | HAProxy Quadlet + masquerade in UFW |
| `monit_haproxy_relay` | Monit healthcheck + port checks |

### Enabling relay for a target

1. Deploy relay node: `just configure --limit relay`
2. Set `mail_relay_wg_ip: "10.99.99.1"` in Kluctl target args
3. Deploy ingress: `just deploy-only ingress/haproxy`
4. Verify: connect via relay, check Dovecot logs show real client IP (`rip=`)

### Disabling relay

1. Remove `mail_relay_wg_ip` (or set empty) in target
2. Redeploy ingress — removes `expect-proxy` directive
3. Direct connections work without PROXY headers
