# 🏴‍☠️ destr0yer-build — Secure K3S Cluster with Ansible

[![CI](https://github.com/youtous/destr0yer-build/actions/workflows/lint.yml/badge.svg)](https://github.com/youtous/destr0yer-build/actions/workflows/lint.yml)
[![pre-commit](https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit&logoColor=white)](https://github.com/pre-commit/pre-commit)
[![Debian - 13 (Trixie)](https://img.shields.io/badge/Debian-13_(Trixie)-a80030)](https://www.debian.org/releases/trixie/releasenotes)
[![K3S](https://img.shields.io/badge/K3S-v1.36-326CE5?logo=kubernetes&logoColor=white)](https://k3s.io/)
[![Cilium](https://img.shields.io/badge/Cilium-1.19-F8C517?logo=cilium&logoColor=white)](https://cilium.io/)
[![Licence](https://img.shields.io/github/license/youtous/destr0yer-build)](https://github.com/youtous/destr0yer-build/blob/master/LICENSE)

> 🛡️ A production-grade, zero-trust **self-hosted Kubernetes platform** for bare-metal
> servers. Provision hardened **Debian 13** nodes with Ansible, deploy a full
> application stack with Kluctl, and expose services through a cloud VPS relay —
> all from a single `just deploy` command.

**Dozens of Ansible roles · Kluctl GitOps components · Documented architecture decisions · Full integration test suite · Zero plaintext secrets.**

```
                          🌐 Internet
                             │
                     ┌───────┴───────┐
                     │  Cloud Relay  │   VPS: WireGuard + HAProxy TCP
                     │  (untrusted)  │   Layer-4 only, never decrypts
                     └───┬───────┬───┘
                         │       │
                    SMTP │       │ HTTPS
                   :465  │       │ :443
            ═════════════╪═══════╪══════════ 🔒 WireGuard mesh ════════
                         │       │
          ┌──────────────┴───────┴──────────────┐
          │          K3S Cluster (bare-metal)    │
          │                                     │
          │  ┌─── Ingress (HAProxy) ──────────┐ │
          │  │ 🌍 who    📊 grafana   🔐 auth │ │
          │  │ 🏠 ha     📧 mail     📁 seafile│ │
          │  └──────┬─────────────────────────┘ │
          │         │ 🔑 Authelia SSO (2FA)     │
          │         ▼                           │
          │  ┌─── 📦 Applications ────────────┐ │
          │  │ Grafana    Home Assistant       │ │
          │  │ Seafile    Zigbee2MQTT/MQTT     │ │
          │  │ Mailserver (DKIM/SPF/DMARC)    │ │
          │  └────────────────────────────────┘ │
          │  ┌─── 👁️ Observability ────────────┐ │
          │  │ Prometheus + Alertmanager       │ │
          │  │ Loki + Alloy (logs + metrics)   │ │
          │  │ Gatus (health) + testssl (TLS)  │ │
          │  └────────────────────────────────┘ │
          │  ┌─── 🛡️ Security ─────────────────┐ │
          │  │ Cilium eBPF (CNI + encryption)  │ │
          │  │ Kyverno (admission policies)    │ │
          │  │ CrowdSec (threat detection)     │ │
          │  │ Tetragon (runtime enforcement)  │ │
          │  │ cert-manager (TLS lifecycle)    │ │
          │  └────────────────────────────────┘ │
          │  ┌─── 💾 Storage & Backup ─────────┐ │
          │  │ OpenEBS hostpath (local PVCs)   │ │
          │  │ Garage S3 (object storage)      │ │
          │  │ Velero + Kopia (3-layer backup) │ │
          │  │ Registry (pull-through cache)   │ │
          │  └────────────────────────────────┘ │
          └─────────┬───────────┬───────────────┘
                  ctrl node   worker node
                 (Debian 13)  (Debian 13)
                    🔥 UFW + fail2ban + SELinux
                    🔒 WireGuard + dnscrypt-proxy
                    📊 Kopia + Monit + Alloy
```

## ✨ What's included

| Layer | Components |
|-------|------------|
| 🐧 **Host OS** | Debian 13 Trixie, kernel 6.12 LTS, nftables, SELinux |
| 🌐 **Networking** | Cilium eBPF (kube-proxy replacement, WireGuard encryption) |
| 🚪 **Ingress** | HAProxy (HTTP/HTTPS/TCP, HSTS, security headers, IP allowlist) |
| 🔐 **TLS** | cert-manager — internal CA (dev) or Let's Encrypt DNS-01 via deSEC (prod) |
| 🪪 **Identity** | Authelia SSO + TOTP 2FA, OIDC provider for Grafana/Seafile |
| 🔒 **VPN** | WireGuard PTP mesh (always-on infra), Headscale planned (admin) |
| 💾 **Storage** | OpenEBS hostpath + Garage S3 + multi-arch registry pull-through cache |
| 👁️ **Observability** | Prometheus + Alertmanager + Grafana + Loki + Alloy + Gatus + testssl |
| 🛡️ **Security** | Kyverno policies, CrowdSec LAPI + nftables bouncer, Tetragon eBPF, fail2ban |
| 💿 **Backup** | Velero (S3 to Garage) + Kopia (SFTP over WireGuard, btrfs snapshots) |
| 📧 **Mail** | docker-mailserver (Postfix, Dovecot, DKIM/SPF/DMARC) + MTA-STS + autodiscover |
| 🏠 **Apps** | Home Assistant, Seafile, Zigbee2MQTT/Mosquitto |
| 🚀 **Deployment** | Ansible (roles for hosts) + Kluctl (components for K8S) |
| ✅ **Testing** | Integration tests + firewall audit + CIS benchmark + NSA/CISA scan |

## ⚡ Five commands to a running cluster

```sh
just setup           # 📦 Install tools + deps
just provision       # 🔧 Bootstrap bare-metal nodes
just configure       # 🛡️ Harden OS, firewall, WireGuard, monitoring
just k3s             # ☸️ Deploy K3S + Cilium
just deploy          # 🚀 Deploy all K8S services via Kluctl
```

Then validate:

```sh
just test-integration   # ✅ Full cluster validation (nodes, pods, Cilium, DNS, Kyverno, certs, ingress...)
just test-firewall      # 🔥 UFW rule audit against expected policy
just audit-cluster      # 🛡️ NSA/CISA + MITRE security scan
```

## 📋 Requirements

System packages (install via your package manager, not asdf):
- [just](https://github.com/casey/just) — command runner
- [Vagrant](https://www.vagrantup.com/) + [libvirt](https://vagrant-libvirt.github.io/vagrant-libvirt/) — local dev VMs (optional)
- QEMU/KVM — hypervisor for Vagrant (`qemu-system`, `libvirt`, `virt-manager`)

Managed by asdf (installed via `just setup`):
- [asdf](https://asdf-vm.com/) or [mise](https://mise.jdx.dev/) — tool version management
- [pipenv](https://pipenv.pypa.io/) — Python dependency management
- All tools in `.tool-versions` (python, helm, k9s, yq, jq, kluctl, sops, kubescape)

## 🏁 Getting started

```sh
git clone https://github.com/youtous/destr0yer-build.git
cd destr0yer-build

just setup           # Install everything
cp .env.sample .env  # Local config
just vault-login     # Set vault password
```

### 🧪 Development environment

#### DevContainer (recommended)

Open in VS Code or Claude Code — Arch Linux container with all tools pre-installed.
Uses `--network=host` to reach Vagrant VMs.

#### Vagrant (local test cluster)

```sh
just ssh-keygen      # 🔑 Generate dev SSH key (.dev/, git-ignored)

# Add the dev public key to your vault:
just vault-edit secret_vars/dev/all.yml
# sudo_user_ssh_keys:
#   - "ssh-ed25519 AAAA... destr0yer-dev"   # paste from .dev/id_ed25519.pub

just ssh-config      # 📝 Write SSH config (User=walle by default)
just vagrant-up      # 🖥️ Start 2 Debian Trixie VMs

# Phase 1 — provision (as vagrant, creates the walle sudo user)
just ssh_user=vagrant provision --user=vagrant --extra-vars='nameservers=["1.1.1.1"]'

# Phase 2 — everything else runs as walle
just configure && just k3s && just deploy

# Phase 3 — post-deploy steps (need running cluster from above)
# a) Garage S3: create buckets + keys, store in SOPS (see kluctl/targets/secrets-reference.yaml)
# b) CrowdSec: register bouncer key, store in vault (see doc/operations.md)
just deploy                    # redeploy after adding Garage S3 keys to SOPS
just configure --tags crowdsec # activate host bouncer after adding API key to vault

just test-integration   # ✅ Validate the cluster
just vagrant-halt       # 💤 Stop VMs
```

> 💡 **SSH user lifecycle**: `just provision` creates the `walle` sudo user.
> All subsequent commands default to `walle`. Override with `just ssh_user=vagrant k9s`.

### 🏭 Production deployment

Same commands, different inventory:

```sh
just env=prod provision --user=root
just env=prod configure
just env=prod k3s
just env=prod deploy
```

### 🎛️ Per-cluster component toggles

Infrastructure (security, storage, ingress, observability) is always deployed.
Application components are opt-in per cluster via `.kluctl.yaml`:

| Component | Toggle | Default |
|-----------|--------|---------|
| 🔐 Authelia (SSO) | `enable_authelia` | `true` |
| 📧 Mailserver | `enable_mail` | `true` |
| 🏠 Home Assistant | `enable_homeassistant` | `true` |
| 📁 Seafile | `enable_seafile` | `true` |
| 🧪 Whoami (test) | `enable_whoami` | `true` |
| 🛡️ CrowdSec | `enable_crowdsec` | `true` |
| 📢 ntfy | `enable_ntfy` | `false` |

## 📁 Project structure

```
playbooks/              🎭 Ansible playbooks (host-level)
  00-provision.yml        Bootstrap new servers (run once as root)
  01-configure.yml        System configuration (users, SSH, firewall, packages)
  02-k3s.yml              K3S cluster deployment
  99-integration-tests.yml  Automated post-deploy checks

kluctl/                 ☸️ Kluctl deployments (K8S-level)
  .kluctl.yaml            Project config + per-target component toggles
  security/               Kyverno, CrowdSec, Tetragon, cert-manager, NetworkPolicies
  observability/          Prometheus, Grafana, Loki, Alloy, Gatus, testssl
  storage/                OpenEBS, Garage S3, registry pull-through, Velero
  ingress/                HAProxy Ingress (HSTS, forward auth, allowlist)
  authelia/               Authelia SSO (OIDC, file-based users, 2FA)
  mail/                   docker-mailserver + MTA-STS + autodiscover + parsedmarc
  home/                   Home Assistant + Mosquitto + Zigbee2MQTT
  apps/                   Seafile (S3 + MariaDB + OIDC)

roles/                  🔧 Ansible roles (host-level)
collections/            📦 Ansible collection youtous.destr0yer (reusable roles)
inventories/            🗂️ Inventory, group_vars, host_vars per environment
doc/                    📚 ADRs, security review, testing strategy
```

## 🎮 Commands

All Ansible runs are logged to `logs/<playbook>-<timestamp>.log` (git-ignored).

| Command | Description |
|---------|-------------|
| **🔧 Host-level (Ansible)** | |
| `just setup` | Install all tools, Python deps, and Galaxy roles |
| `just provision` | Bootstrap new servers (run once as root) |
| `just configure` | System configuration (firewall, SSH, WireGuard, monitoring) |
| `just k3s` | Deploy K3S cluster |
| **☸️ K8S-level (Kluctl)** | |
| `just deploy` | Deploy all K8S components |
| `just deploy-only observability/loki` | Deploy a specific component |
| `just diff` | Preview changes before applying |
| `just render` | Render templates offline (no cluster needed) |
| `just prune` | Remove orphaned K8S resources |
| **🖥️ Cluster access** | |
| `just k9s` | Open k9s on ctrl (RBAC-limited operator kubeconfig) |
| `just kubectl get pods -A` | Run kubectl on ctrl |
| `just kubectl-admin ...` | 🚨 Break-glass admin kubeconfig (emergency only) |
| `just garage status` | Run garage CLI inside garage-0 pod |
| **🔐 Secrets** | |
| `just vault-edit <file>` | Edit Ansible Vault file (host-level secrets) |
| `just sops-edit <file>` | Edit SOPS-encrypted file (kluctl targets) |
| **✅ Testing & operations** | |
| `just lint` | Pre-commit hooks (yamlfmt, ansible-lint) |
| `just test-integration` | Automated checks on the deployed cluster |
| `just test-firewall` | UFW rule audit against expected policy |
| `just audit-node <host>` | CIS K3S benchmark on a node |
| `just audit-cluster` | NSA/CISA + MITRE security scan |

## 🛡️ Security model

```
🌐 Internet ──▶ 🔥 UFW (deny all) ──▶ 🔒 WireGuard (encrypted mesh)
                                              │
                              🕸️ Cilium NetworkPolicy (default-deny per namespace)
                                              │
                              📋 Kyverno (digest-only images, resource limits, PSA restricted)
                                              │
                              🚨 CrowdSec (threat detection) + Tetragon (runtime eBPF)
                                              │
                              🔐 Authelia (SSO + 2FA forward auth)
                                              │
                                          📦 Application
```

- 🚫 **Zero-trust networking** — all inbound blocked on bare-metal, SSH restricted to known IPs
- 🧅 **Defense in depth** — multiple layers from UFW to application-level auth
- 🔒 **Egress control** — default-deny on all pods, internet access restricted to essential components only
- 📌 **Image security** — all images pinned by SHA256 digest, Kyverno enforces digest-only pulls
- 🔑 **Secrets** — Ansible Vault (hosts) + SOPS/age (K8S), zero plaintext on disk
- 🔔 **Alerting** — Prometheus Alertmanager (custom rules) + reporting CronJobs (email)
- 📝 **Audit** — K3S API audit log shipped to Loki via Alloy

See [doc/security.md](doc/security.md) for the full gap analysis and network policy matrix.

## 🔑 Secrets management

Two independent encrypted stores — no sync needed between them:

| Store | Scope | Encryption | Tool |
|-------|-------|------------|------|
| 🏰 Ansible Vault | Host-level (SSH keys, passwords, WireGuard) | AES-256 | `just vault-edit` |
| 🔐 SOPS + age | K8S-level (Kluctl secrets, S3 keys, OIDC) | X25519 | `just sops-edit kluctl/targets/<env>.enc.yaml` |

```sh
just vault-login                            # Set vault password
just vault-edit secret_vars/<env>/all.yml   # Edit host-level secrets
just sops-edit kluctl/targets/<env>.enc.yaml  # Edit K8S-level secrets
just sops-init                              # First-time: generate age keypair
just push / just pull                       # Backup/restore secrets
```

See [doc/operations.md](doc/operations.md#secrets-management) for detailed procedures.

## 🌍 Accessing services

Services run on the `k8s.home` domain. Add entries to `/etc/hosts` pointing to
the cluster ingress IP.

| Service | URL | Auth |
|---------|-----|------|
| 📊 Grafana | `https://grafana.k8s.home` | OIDC via Authelia (or admin login) |
| 🔐 Authelia | `https://auth.k8s.home` | File-based users + TOTP 2FA |
| 🏠 Home Assistant | `https://ha.k8s.home` | Native (setup wizard) |
| 📁 Seafile | `https://seafile.k8s.home` | OIDC via Authelia |
| 🧪 Whoami | `https://who.k8s.home` | Authelia forward auth |
| 📋 Gatus | `https://status.k8s.home` | Status page |

## 📝 Post-deploy operations

Some components require one-time manual steps after `just deploy`.
Full procedures: [doc/operations.md](doc/operations.md).

| Step | Action | Details |
|------|--------|---------|
| 1 | Garage S3 layout + buckets + keys | `just garage status` → assign layout → create keys/buckets → `just sops-edit` → `just deploy` |
| 2 | Authelia first login | Visit `https://auth.k8s.home`, register TOTP 2FA |
| 3 | Grafana data sources | Visit `https://grafana.k8s.home`, verify Prometheus + Loki |
| 4 | Velero backups | `just kubectl get backupstoragelocations -n velero` (phase = Available) |
| 5 | Home Assistant | Visit `https://ha.k8s.home`, complete onboarding wizard |
| 6 | CrowdSec bouncer | Generate key from LAPI, store in vault, `just configure --tags crowdsec` |
| 7 | Mailserver DNS (prod) | MX, SPF, DKIM, DMARC, MTA-STS records |
| 8 | cert-manager deSEC (prod) | Store deSEC token in SOPS, delegate `_acme-challenge` CNAME |

## 📦 Reusable Ansible collection

The `youtous.destr0yer` collection contains standalone roles:

| Role | Description |
|------|-------------|
| 🔥 `youtous.destr0yer.ufw_smart_rules` | Declarative UFW firewall reconciliation |
| 👤 `youtous.destr0yer.users` | User, group, and SSH key management |
| 📋 `youtous.destr0yer.logwatch` | Logwatch installation and configuration |

## 📚 Documentation

- 📐 [Architecture decisions (ADRs)](doc/adr/)
- 🛡️ [Security review](doc/security.md)
- ✅ [Testing strategy](doc/testing.md)
- 🕸️ [Network policies egress matrix](kluctl/security/network-policies/README.md)
- 💾 [USB disk storage](doc/usb-storage.md)
- 🔐 [Certificate management](doc/certificates.md)
- 📖 [Operations guide](doc/operations.md)
- 🌐 [Proposal: White hole relay pattern](doc/proposal-white-hole-extended.md)
- 📢 [Proposal: ntfy push notifications](doc/proposal-ntfy-push-notifications.md)
- 🤖 [AI onboarding (CLAUDE.md)](CLAUDE.md)

## 🗺️ Roadmap

- [ ] 🦾 ARM64 full stack validation
- [ ] 💾 OpenEBS Mayastor (multi-node replicated storage)
- [ ] 📧 Mailserver DNS + cloud relay end-to-end
- [ ] 🔄 DR test: etcd snapshot restore
- [ ] 📢 ntfy + Alertmanager notification pipeline
- [ ] 🔐 Let's Encrypt via deSEC (prod)
- [ ] 💾 Garage multi-site replication (2-zone layout over WireGuard)
- [ ] 🌐 Cilium Gateway API (when HAProxy limits reached)

## 📜 Licence

[GPLv3](LICENSE) — Author [@youtous](https://github.com/youtous)
