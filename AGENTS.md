# destr0yer-build

Ansible playbooks for provisioning and managing a hardened K3S Kubernetes cluster.

## Quick reference

- **Stack**: Ansible + K3S + Cilium CNI + Cilium Gateway API + HAProxy Ingress (TCP) + cert-manager + Authelia
- **Target OS**: Debian 13 (Trixie)
- **Dev env**: Vagrant + KVM/libvirt (local), DevContainer (Claude Code)
- **Python**: 3.13 via asdf, dependencies via pipenv
- **CI**: GitHub Actions (lint + release)
- **Language**: English for all code, comments, docs, and commit messages

## Repository structure

```
playbooks/          Ansible playbooks (00-provision, 01-configure, 02-k3s, dev-dns)
roles/              Ansible roles (k3s_*, k8s_*, system, networking, monitoring, cloud_relay, cloud_provider_cleanup)
collections/        Ansible collection youtous.destr0yer (ufw_smart_rules, users, logwatch)
kluctl/             Kluctl deployments (K8S-level: security, storage, database, observability, mail, apps, home)
inventories/dev/    Inventory files and group_vars/host_vars
archive/            (removed — Swarm code lives in git history only)
doc/                Architecture decisions, guides, and documentation
logs/               Ansible run logs (git-ignored, one file per run)
```

## Key commands

```sh
# Ansible (host-level) — all runs logged to logs/<playbook>-<timestamp>.log
just setup           # Install all tools + deps + galaxy roles
eval "$(just vault-login)"  # Set vault password (bash); just vault-login | source (fish)
just provision       # Run 00-provision playbook
just configure       # Run 01-configure playbook
just k3s             # Run 02-k3s playbook
# Kluctl (K8S-level) — runs on ctrl as operator user (no root, no admin kubeconfig)
just sync            # Sync workspace to ctrl (~/destr0yer-build/) for SSH debugging
just render          # Render templates offline (local, no cluster needed)
just diff            # Preview K8S changes (via Ansible on ctrl)
just deploy          # Deploy all K8S components (via Ansible on ctrl)
just deploy-only observability/loki  # Deploy specific component
just deploy-manual   # Sync workspace + print kluctl command for manual SSH execution
just prune           # Remove orphaned K8S resources

# Interactive cluster access — operator kubeconfig (~/.kube/operator.yaml, RBAC-limited)
just k9s             # Open k9s on ctrl via SSH
just kubectl get pods -A   # Run kubectl on ctrl via SSH
just kubectl-admin ...     # Break-glass: sudo breakglass-kubectl (emergency only)
just garage status   # Run garage CLI inside garage-0 pod

# Secrets
just vault-edit inventories/<env>/group_vars/all/vault.yml  # Edit Ansible Vault secrets
just sops-edit kluctl/targets/<env>.enc.yaml  # Edit SOPS-encrypted K8S secrets

# Dev tools
just dev-dns         # Add k8s.home DNS entries to local /etc/hosts
just mailpit         # Start mailpit SMTP catcher via podman on host
just mailpit-stop    # Stop mailpit container

# Shared
just lint            # Run pre-commit hooks (must always pass)
just sops-edit kluctl/targets/<env>.enc.yaml # Edit SOPS-encrypted K8S secrets

# Version management
./scripts/check-versions.sh                # List all component versions
./scripts/check-versions.sh --check-updates # Check for newer versions (needs helm, crane, curl, jq)

# Validation (in container, no VMs needed)
just render                              # Uses ENV from .env (default: dev)
just render --include-tag security       # Render subset

# Integration testing (needs Vagrant VMs running)
just test-integration
just test-firewall
```

## Environment variable — single source of truth

A single variable `ENV` in `.env` drives the entire stack:

| What it controls | How |
|-----------------|-----|
| Ansible inventory path | `inventories/$ENV/` |
| Kluctl target | `targets/$ENV.yaml` + `targets/$ENV.enc.yaml` |
| SSH hosts | derived from inventory (e.g. `ctrl.k3s.$ENV.local`) |

```sh
# Set once in .env (loaded by justfile via `set dotenv-load`)
ENV=dev

# Override per-command
just env=prod deploy
just env=prod render

# Or export for the whole session
export ENV=prod
just deploy
```

All `just` recipes (provision, configure, k3s, deploy, diff, render, prune, test-*) read `ENV` and route to the correct inventory and kluctl target automatically.

## Sensitive files — never commit unencrypted

- `inventories/*/group_vars/*/vault*.yml` and `inventories/*/host_vars/*/vault*.yml` — Ansible Vault encrypted (auto-loaded by Ansible)
- `kluctl/targets/*.enc.yaml` — SOPS encrypted (age key). Contains:
  - `secrets.grafana_admin_password` — Grafana admin password
  - `secrets.garage_rpc_secret` — Garage inter-node RPC key
  - `secrets.garage_admin_token` — Garage admin API token (port 3903, not exposed via ingress)
  - `secrets.authelia_jwt_secret` — Authelia JWT HMAC key
  - `secrets.authelia_session_key` — Authelia session encryption key
  - `secrets.authelia_storage_key` — Authelia storage encryption key
- `.vault_password` — Script that reads VAULT_PASSWORD from env, git-ignored
- `.env` — Local config (ENV), git-ignored. `ENV` is the single source of truth for environment selection.
- `$SOPS_AGE_KEY_FILE` (default `.keys/<env>-sops.age`) — SOPS age private key, per-env, git-ignored (on GitHub)

**Secrets sync**: Vault files (`vault*.yml`) are git-ignored by default. On private forks,
remove the vault lines from `.gitignore` and commit them on the `deploy/master` branch.
GitHub remote is read-only (`git remote set-url --push origin DISABLED`). Push protection:
local pre-push hook blocks `deploy/*` to non-private remotes + GitHub branch rule rejects
`deploy/**` server-side. Future: push to self-hosted Forgejo.

## Conventions

- Roles are prefixed by scope: `k3s_*` (cluster), `k8s_*` (kubernetes tools), `monit_*` (monitoring)
- Youtous-authored roles live in `collections/ansible_collections/youtous/destr0yer/roles/` and are referenced by FQCN (e.g. `youtous.destr0yer.ufw_smart_rules`)
- All container images must be pinned to specific versions, never use `:latest`
- All images in custom manifests (CronJobs, init containers, sidecars) must be pinned by digest (`@sha256:...`) with the tag in a trailing comment (`# v1.2.3`)
- **Utility image**: `docker.io/alpine/k8s` is the single utility image for all CronJobs, init containers, and helper pods. Do not introduce `busybox`, `curlimages/curl`, `alpine/curl`, or bare `alpine` — use `alpine/k8s` instead. Rationale: one image to track/update, reduced attack surface (Alpine-based, minimal), and it bundles kubectl, helm, curl, jq, bash, wget. Pin to the version matching the K3S cluster (e.g. `1.36.x` for K3S v1.36). Exception: app-specific images that need their own CLI (e.g. `crowdsecurity/crowdsec` for `cscli`).
- Never use Bitnami images (deprecated, unreliable tags) — prefer upstream images
- Ansible collections are version-pinned in `requirements.yml`
- External roles are pinned by commit SHA in `requirements.yml`
- All documentation and code in English
- Kluctl uses target args for env-specific behavior (e.g. `kyverno_validation_action: Audit|Enforce`)
- Pre-commit must always pass — fix failures even if they seem out of scope
- USB disk storage uses existing `filesystems_to_create` from `disks_lvm_management` — no separate role. SMART monitoring via `smartmontools` + `monit_usb_storage`. See [doc/usb-storage.md](doc/usb-storage.md)
- **UFW rules**: If a port is a dependency of an Ansible role, the role manages its own rule via `ufw_smart_rules` (self-contained). `ufw_additional_rules` in inventory is only for ports not managed by any Ansible role (e.g. HAProxy Ingress ports deployed via Kluctl).

### File permissions — least privilege by default

Always apply the most restrictive permissions possible:

| Resource type | Mode | Owner | Rationale |
|--------------|------|-------|-----------|
| System binaries (`/usr/local/bin/*`) | `0755` | `root:root` | Must be executable by all users |
| System config dirs (`/etc/haproxy`, `/etc/monit`) | `0755` | `root:root` | System services need read access |
| Data files (`/etc/hosts`, config files) | `0644` | `root:root` | Readable, **never executable** |
| Service data dirs (alloy, kopia cache) | `0750` | `svc_user:svc_group` | No world access |
| Secrets (TLS keys, DKIM, vault) | `0600` | owner only | No group, no other |
| User home dirs (functional users) | `0700` | user:user | No group, no other |
| Backup chroot dirs | `0750` | `root:backup_group` | SFTP chroot requires root-owned, group-traversable |

Rules when writing Ansible tasks:
- **Never use `0755` on data files** — use `0644` (or `0640`/`0600` for sensitive data)
- **Never use `o=rx` on service/user directories** — use `o=` unless there's a documented reason
- **Functional users** (mail-dms, alloy, backup) get `0700` homes — no group/other access
- **`failed_when: false`** must only swallow expected failures (e.g. "already initialized"). Always use `failed_when` with a condition, never bare `false`.

### Systemd service hardening — sandboxing checklist

All custom systemd services (Kopia, Alloy, custom oneshots) should apply these restrictions:

```ini
# Filesystem isolation
ReadOnlyPaths=/                    # Entire filesystem read-only
ReadWritePaths=/specific/paths     # Only paths the service needs to write
WorkingDirectory=/appropriate/dir  # Explicit CWD (no reliance on defaults)

# Privilege restriction
NoNewPrivileges=yes                # Block setuid/capabilities escalation

# Network restriction
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6  # Only needed socket types
```

When adding a new systemd service:
1. Start with `ReadOnlyPaths=/` + explicit `ReadWritePaths` for known write targets
2. Add `NoNewPrivileges=yes` unless the service needs to escalate (rare)
3. Restrict socket families unless the service needs exotic sockets (netlink, bluetooth)
4. Use `ExecStartPre=/bin/mkdir -p` for directories that may not exist yet
5. Do **not** use `ProtectSystem=strict` together with `ReadOnlyPaths=/` (redundant, can conflict)
6. Test with `systemd-analyze security <unit>` to verify the hardening score

### Secrets in Kluctl manifests — zero plaintext rule

**Every `secrets.*` value must end up in a `kind: Secret` resource.** No exceptions.

Checklist when writing or reviewing a Kluctl manifest that uses `secrets.*`:

1. **Never put `secrets.*` in a ConfigMap** — if the config file contains a secret (e.g. `garage.toml` with `admin_token`), make the whole resource a `kind: Secret` instead.
2. **Never use `value: "{{ secrets.* }}"` in a pod env var** — always use `valueFrom.secretKeyRef` pointing to a K8s Secret.
3. **Never inline credentials in Helm values** — use the chart's `existingSecret` / `secretKeyRef` pattern. Create the Secret separately and reference it by name.
4. **Secrets must not cross namespaces** — if a Job needs a secret from another namespace, move the Job to the namespace that owns the secret. Never duplicate a Secret into another namespace.
5. **Garage admin token stays in `garage` namespace** — all admin operations (bucket creation, key provisioning) are manual via `garage` CLI. See `kluctl/targets/secrets-reference.yaml` for the full procedure.
6. **Helm charts that create their own Secrets** (e.g. Authelia `value:` fields, Velero `credentials.existingSecret`) are acceptable — the chart internally wraps them in `kind: Secret`. When in doubt, check the rendered output with `kluctl render`.

Quick audit command — run after any change that touches `secrets.*`:
```sh
# Rendered manifests must never have secrets.* in non-Secret resources
RENDERED=$(kluctl render -t dev --project-dir kluctl/ --offline-kubernetes --kubernetes-version 1.36 2>&1 | grep "Rendered into" | awk '{print $3}')
# Check: no ConfigMap should contain sensitive-looking values
rg -l 'kind: ConfigMap' "$RENDERED" | xargs rg -l 'token|password|secret|credential|api_key|private.key' || echo "OK — no leaks"
```

## Architecture decisions

Detailed ADRs are in [doc/adr/](doc/adr/). Key decisions:

- **K3S over Docker Swarm**: Migration complete. Legacy Swarm code removed (git history)
- **Debian 13 Trixie**: Kernel 6.12 LTS, nftables native, better eBPF support
- **Cilium CNI**: eBPF networking, encryption, kube-proxy replacement
- **HAProxy Ingress**: DaemonSet with hostNetwork, default IngressClass (Traefik disabled in k3s)
- **OpenEBS hostpath**: Lightweight persistent storage (minimal overhead)
- **Loki + Alloy**: Centralized logging (replaces archived Elastic stack)
- **WireGuard plane separation** (ADR-005 revised): 4 independent WG planes with isolated keys — `wg-admin` (admin ops), `wg-relay-admin` (relay SSH), `wg-infra-ext` (relay ↔ ctrl services), `wg-infra-int` (inter-cluster mesh). Intra-cluster pod networking handled by Cilium (not WG). See [doc/networking.md](doc/networking.md#wireguard-plane-separation) for topology and [doc/security.md](doc/security.md#wireguard-plane-isolation) for threat model.
- **Multi-cluster**: One K3S cluster per geographic zone. Clusters are independent. Inter-cluster traffic via `wg-infra-int`, admin access via `wg-admin` (direct for fixed IP, DNAT via relay otherwise).
- **Cloud relay**: Public-facing forwarder for mail/web. WireGuard `wg-infra-ext` + HAProxy TCP (dual-stack IPv4/IPv6, PROXY protocol v2). No TLS termination on relay. Relay is zero-trust for admin traffic (blind UDP DNAT only).
- **Zero-trust** (ADR-008): All inbound blocked on bare-metal. SSH restricted to known IPs (entrypoint_ssh). Relay is the only node with public ports.
- **SSH relay pattern**: Bootstrap-then-lock — cloud provider firewall gates public SSH during initial provisioning, closed after WireGuard validated. Remote admin access via `wg-admin` plane (relay = blind DNAT on port 41994, admin authenticates directly on ctrl by WG key). See [doc/security.md](doc/security.md#remote-admin-access--wireguard-planes).
- **cert-manager**: TLS certificate lifecycle — internal CA (dev) or Let's Encrypt via deSEC DNS-01 (prod)
- **Garage**: S3-compatible object storage (backend for Loki/backups), admin via `kubectl exec`
- **Ingress**: HAProxy for all HTTP/HTTPS + TCP (mail). Cilium Gateway API deferred.
- **CrowdSec**: K8S-level threat detection + HAProxy SPOA bouncer (IP ban at ingress), fail2ban kept on host level. Custom SASL brute-force scenario (`custom/postfix-sasl-bf`). Online API (community blocklist) via `crowdsec_online_api` arg (off in dev, on in prod)
- **Cloud provider cleanup**: Removes Scaleway/Hetzner/OVH/DigitalOcean services, packages, binaries on first provision
- **Authelia**: SSO/OIDC provider, file-based users, 2FA (`auth.k8s.home`)
- **Home Assistant**: Smart home platform (`ha.k8s.home`)
- **Private registry**: Pull-through cache (multi-arch ARM64+AMD64)
- **Kopia**: Backup via SFTP over WireGuard to dedicated btrfs backup node
- **Mailpit**: Dev SMTP catcher — runs on VM host via podman, not inside K8S
- **Kluctl force-apply** (ADR-037): `--force-apply` by default on all deploys + `conflictResolution` in `deployment.yaml`. Prevents silent SSA field ownership loss that caused config changes to be ignored.

## Testing (see [doc/testing.md](doc/testing.md))

- **Lint** (in container): `just lint` — must pass, always fix failures
- **Kluctl render** (in container): validates templates without a cluster
- **Integration** (Vagrant VMs): `just test-integration`
- **Firewall audit** (Vagrant VMs): `just test-firewall`
- **Security audit** (manual, maintenance): `just audit-node` + `just audit-cluster` + `just audit-lynis` + `just audit-systemd`
- CI: GitHub Actions runs lint on push/PR

## Security (see [doc/security.md](doc/security.md))

Implemented: SELinux (permissive), audit logging, PSA restricted, default-deny NetworkPolicy, Cilium encryption, fail2ban host-level, systemd service sandboxing, Lynis-driven host hardening (sysctl, file permissions, SSH, login.defs).

Kyverno policies use `args.kyverno_validation_action` — `Audit` in dev, `Enforce` in prod.

Systemd hardened services: Alloy, DNSCrypt-proxy, Monit, Fail2ban, Glances, Kopia (snapshot + verify). Each service has tailored restrictions — see `doc/security.md` for the full posture table.

## Cluster access model

Three tiers — admin kubeconfig (`/etc/rancher/k3s/k3s.yaml`) stays root-only, never used for routine ops:

```sh
# 1. Deploy (kluctl as operator user, become: false, operator kubeconfig $HOME/.kube/operator.yaml)
just deploy                          # all components
just deploy-only observability/loki  # single component
just deploy-manual                   # sync + print command for manual SSH execution
just diff                            # preview changes
just sync                            # sync workspace to ~/destr0yer-build/ for SSH debugging

# 2. Interactive ops (SSH to ctrl, operator kubeconfig, RBAC-limited, no system:masters)
just k9s                  # k9s on ctrl
just kubectl get pods -A  # kubectl on ctrl

# 3. Break-glass (sudo breakglass-kubectl — admin kubeconfig, emergency only)
just kubectl-admin get nodes
```

```sh
# SSH setup (one-time, configures ~/.ssh/config for Vagrant VMs)
just ssh-config

# SSH to VMs (uses ~/.ssh/config — key .dev/id_ed25519, no User hardcoded)
ssh ctrl.k3s.dev.local
ssh worker.k3s.dev.local

# Ansible ad-hoc (needs vault password)
BECOME_PASS=$(pipenv run ansible-vault view inventories/dev/group_vars/all/vault.yml --vault-password-file .vault_password | grep sudo_user_clear_password | cut -d'"' -f2)
pipenv run ansible ctrl.k3s.dev.local -i inventories/dev/base-nodes.yml -u walle --become -m shell -a "..." -e "ansible_become_pass=$BECOME_PASS" --vault-password-file .vault_password
```

## Current state

Both VMs operational:
- `just configure`: passes on both nodes
- `just k3s`: passes, K3S cluster operational, operator kubeconfig deployed
- `just deploy`: kluctl sync + deploy works, all infra + app components deployed
- `just test-integration`: **all passed**
- `just test-firewall`: **passed**
- Kluctl render: passes offline

Running services (Ingresses):
- `who.k8s.home` — whoami (test/health check)
- `auth.k8s.home` — Authelia SSO
- `ha.k8s.home` — Home Assistant
- `grafana.k8s.home` — Grafana (observability, OIDC via Authelia when auth_mode=authelia)

Validated subsystems:
- **Observability**: Prometheus, Loki, Grafana — all datasources healthy
- **Velero**: Backup/restore cycle tested (backup → delete → restore → running)
- **Kopia**: Host-level SFTP backup active on both nodes, systemd timers running
- **CrowdSec**: LAPI + agents + HAProxy SPOA bouncer — ban/unban tested end-to-end
- **Mailserver**: Pods running (SMTP/IMAP responsive), config incomplete without relay/DNS (expected in dev)

## Known dev limitations

- **SSH prerequisite**: Run `just ssh-config` once before using any `[dev]` recipe (configures `~/.ssh/config` for Vagrant VMs)
- **No `ansible_host`**: Inventory relies on SSH config for hostname resolution — do not set `ansible_host` in dev host_vars
- **Mailpit**: Dev uses mailpit on host (podman) for SMTP catch-all; mailserver role still deploys in K8S for testing
- **Authelia**: Needs real domain + session config (dev uses internal CA)
- **DevContainer**: Supports VM access via SSH (rsync included). VMs require local Vagrant+KVM host.
- **Kopia SFTP timing**: During `just configure`, the firewall role may temporarily block WG connections while reloading. Kopia retries (6x15s) handle this, but the first run on a fresh setup may require a second `just configure` pass for the worker node.
- **zigbee2mqtt**: CrashLoopBackOff in dev (no USB Zigbee hardware) — excluded from integration tests
- **parsedmarc**: Intermittent OOMKill on CronJob — excluded from integration tests

## Next steps (priority order)

| # | Task | Complexity | What to do |
|---|------|-----------|------------|
| 0 | DR test: etcd restore | Medium | Script etcd snapshot restore on Vagrant |
| 1 | Mailserver DNS + prod relay | Medium | External DNS (SPF/DKIM/DMARC), prod SMTP TLS/auth, end-to-end test |
| 2 | ntfy activation + alerting pipeline | Low | Set `enable_ntfy: true`, wire Alertmanager → ntfy for notifications |
| 3 | Let's Encrypt via deSEC | Low | Add `desec_token` secret + `cluster_domain` in prod target (infra ready) |
| 4 | ARM64 validation | Medium | Test full stack on ARM64 (Vagrant aarch64 or real hardware) |
| 5 | OpenEBS Mayastor | Medium | Multi-node replicated storage (replace hostpath for HA workloads) |
| 6 | Garage multi-site replication | Medium | 2-zone layout across sites, RPC over WireGuard, `toCIDR` NetworkPolicy (ADR-012) |
| 7 | Zigbee2MQTT USB dongle | Low | Validate USB passthrough to K8S pod on real hardware (ADR-031) |
| 8 | Seafile client-side encryption | Low | Enable encrypted libraries for sensitive data (ADR-032) |
| 9 | IPv6 dual-stack | High | K3S dual-stack + relay HAProxy IPv6 binds + UFW/Cilium rules (ADR-036) |
| 10 | Authelia access control | Medium | Create `users` group, map proper ACL rules (bypass/1FA/2FA), fix current rules that downgrade 2FA for admins |
| 11 | SELinux enforcing mode | High | Audit AVC denials in permissive (`ausearch -m AVC`), write custom policy modules (`audit2allow`), test each service (K3S, containerd, dnscrypt, alloy, monit, WireGuard). Debian refpolicy is stricter than RHEL targeted — requires thorough validation on Vagrant before prod. |

### Completed validations

| What | Result |
|------|--------|
| Full test loop (`configure` + `k3s` + `deploy`) | Passes on both nodes |
| Integration tests | All passed |
| Firewall audit | Passed |
| kube-bench CIS | Within threshold — residual FAILs are accepted (see below) |
| Observability (Prometheus + Loki + Grafana) | All datasources healthy, scrape targets OK |
| Velero backup/restore | Full cycle tested (backup → delete → restore → running) |
| Kopia host-level backup | Snapshots OK, timers active on both nodes |
| CrowdSec HAProxy bouncer | Ban/unban tested end-to-end |
| CrowdSec host nftables bouncer | Deployed on both nodes, connected to LAPI via NodePort |
| Grafana OIDC | Validated via Authelia login |
| Seafile S3 + OIDC | Validated (encryption is client-side, Garage buckets exist) |
| Multi-arch registry audit | Passed — few amd64-only exceptions (parsedmarc, mail-autodiscover) |
| Lynis host audit | Installed, `just audit-lynis` available (target ≥ 80/100) |
| Systemd hardening | 7 services sandboxed (Alloy, DNSCrypt, Monit, Fail2ban, Glances, Kopia×2) |
| Host hardening (Lynis-driven) | Sysctl, SSH, file permissions, login.defs SHA rounds, wpa_supplicant removed |

### ADRs needing live validation (cannot be done offline)

| ADR | What's needed | Effort |
|-----|--------------|--------|
| 012 (Garage S3) | Prod: multi-node replication config | Medium (needs 2nd node) |
| ~~015 (Registry)~~ | ~~Audit all images for multi-arch~~ — done: 2 single-arch flagged | ~~Done~~ |
| 023 (DR) | Test etcd snapshot restore on Vagrant | Medium |
| 024 (cert-manager) | Let's Encrypt via deSEC — blocked until prod DNS setup (wildcard) | Blocked |

### CIS hardening — accepted residual FAILs

| Check | Reason | Fixable? |
|-------|--------|----------|
| 5.1.1 | `cluster-admin` bound to Cilium, Kyverno, cert-manager SAs | No — required by charts |
| 5.1.3 | Wildcard verbs/resources in Cilium, Kyverno ClusterRoles | No — upstream design |

Not yet prioritized:
- Cilium Gateway API (HAProxy handles all current ingress needs)
- OpenEBS Mayastor (multi-node replicated storage — see ADR-003 evolution path)

See [doc/operations.md](doc/operations.md) for operational procedures (Kyverno mode, cert-manager, retention, alerts).

## Kluctl deploy workflow

**Prefer `just deploy` or `just deploy-only <path>` to deploy K8S changes.**

Manual rsync + SSH is allowed for debugging, but be aware of the difference:
- `just deploy` is the **canonical path** — it handles secret sync, SOPS key deployment (with 30 min auto-cleanup), and runs kluctl with the operator kubeconfig (RBAC-limited).
- Manual rsync + SSH skips secret consistency checks, uses whatever kubeconfig/key is already on the node, and won't auto-cleanup the SOPS key.

What `just deploy` does under the hood:
1. Syncing secrets from Ansible Vault to SOPS (consistency check)
2. Syncing the workspace to ctrl via `ansible.posix.synchronize`
3. Deploying SOPS age key with auto-cleanup (30 min)
4. Running kluctl with `--force-apply` and the operator kubeconfig (RBAC-limited, not admin)

### Force-apply by default (ADR-037)

All kluctl operations use `--force-apply` to prevent silent SSA field ownership loss. Without it, kluctl's server-side apply can lose ownership of `data`/`spec` fields, causing subsequent deploys to silently skip configuration changes. Combined with `conflictResolution` in `kluctl/deployment.yaml`, this ensures kluctl always remains the sole owner of all deployed fields. See [ADR-037](doc/adr/037-kluctl-force-apply.md) for details.

### Kluctl include filtering — tags, not directories

`just deploy-only <path>` extracts the basename of the path and passes it as `-I <tag>` (kluctl `--include-tag`). Kluctl auto-generates tags from directory names, so `just deploy-only observability/promgraf` uses tag `promgraf`.

**Warning**: kluctl's `-I` flag is `--include-tag`, **not** `--include-deployment-dir`. The `--include-deployment-dir` flag exists but does not correctly match nested deployment includes in kluctl v2.27.0. Always use tag-based filtering.

### Kluctl command result store — disabled

`--write-command-result=false` is set in `playbooks/kluctl-ops.yml`. The full deploy output exceeds the 1MB Kubernetes Secret size limit, causing a write failure at the end of every deploy. Since we capture the complete kluctl output via Ansible (`Show kluctl output` task), the in-cluster result store is redundant.

Impact: `kluctl webui` and `kluctl results` won't have deploy history. If needed in the future, kluctl would need an external result backend (not yet supported) or the deploy scope would need to be reduced to fit under 1MB.

```sh
just deploy                              # full deploy (all components)
just deploy-only security/kyverno        # single component (uses tag "kyverno")
just deploy-only observability/promgraf  # single component (uses tag "promgraf")
just diff                                # preview without applying
just prune                               # remove orphaned resources
just render                              # local render only (no cluster needed)
```

For debugging a failed deploy interactively on ctrl:
```sh
just deploy-manual   # syncs workspace + prints the kluctl command to run via SSH
just sync            # sync workspace only (for SSH debugging)
```

## Agent workflow — when to use Cursor vs direct edits

### Do it yourself (Claude Code direct)
- Edits < 5 files
- Debugging (read logs, fix a value, retry)
- Ansible ad-hoc commands / playbook runs
- Kluctl deploy via `just deploy` / `just deploy-only`
- Git operations
- Architecture decisions, doc updates
- Any feedback loop (fix -> test -> fix)

### Delegate to Cursor Agent (`cursor-agent --model claude-4.6-opus-max`)
- Bulk mechanical operations (create 10+ files with same pattern)
- Mass renaming / refactoring across many files
- Scaffolding (new role structure, new Kluctl component)
- Renovate annotations on 10+ files
- Any task where the output doesn't need to be read in detail

### Cursor rules
- Always use `--model claude-4.6-opus-max --print --yolo`
- One focused task per request (not 10 tasks in one prompt)
- Scope files explicitly (READ: ..., MODIFY: ..., FORBIDDEN: ...)
- Use `timeout 300` wrapper for long tasks
- After 2 failures on the same task, stop and debug manually
- System reminders from Cursor-modified files consume context — prefer direct edits for small changes
