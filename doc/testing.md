# Testing Strategy

Decision: [ADR-009](adr/009-ci-github-actions.md) (CI/CD)

## Layers

```
┌─────────────────────────────────────────────────┐
│ Layer 1: Lint (in container)                    │
│   just lint                                     │
│   pre-commit: yamlfmt + ansible-lint + yamllint │
│   Runs: on every change                         │
├─────────────────────────────────────────────────┤
│ Layer 2: Kluctl render (in container)           │
│   kluctl render -t dev --offline-kubernetes     │
│   Validates all Helm charts + Jinja2 templates  │
│   Runs: after any kluctl/ change                │
├─────────────────────────────────────────────────┤
│ Layer 3: Integration tests (Vagrant + Ansible)  │
│   vagrant up → just provision → just configure  │
│   → just k3s → just test-integration            │
│   Full cluster deployment + validation          │
│   Runs: before merging, during maintenance      │
├─────────────────────────────────────────────────┤
│ Layer 4: Firewall audit (post-build)            │
│   playbooks/98-firewall-audit.yml               │
│   Validates UFW state against expected rules    │
│   Runs: after full build, during maintenance    │
└─────────────────────────────────────────────────┘
```

No Molecule — focus on real integration tests against Vagrant VMs.
Role-level unit tests add complexity without catching the issues that matter
(cross-role interactions, real K3S behavior, Cilium networking).

## Setup

The dev SSH key is stored in the workspace (`.dev/id_ed25519`, git-ignored).
The devcontainer uses `--network=host` to reach VMs on `192.168.56.0/24`.

```sh
# One-time setup
just ssh-keygen       # Generate dev SSH key in .dev/
just ssh-config       # Add VM hosts to ~/.ssh/config

# Start VMs (on host — Vagrant needs KVM/libvirt)
vagrant destroy -f && vagrant up
```

## Integration test workflow

```sh
# Deploy the full stack (from devcontainer)
just provision        # Initial provisioning (apt, users, SSH keys)
just configure        # System config (firewall, SELinux, dnscrypt, monit, backup)
just k3s              # K3S cluster + Cilium + HAProxy ingress

# Run integration tests
just test-integration

# Firewall audit (validates UFW rules match expectations)
ansible-playbook playbooks/98-firewall-audit.yml \
  -i inventories/dev/base-nodes.yml \
  -i inventories/dev/k3s-cluster.yml \
  -e server_environment=dev \
  --vault-password-file .vault_password
```

**Important**: provision does NOT configure DNS resolver (resolv.conf).
DNS is configured in `01-configure.yml` after dnscrypt-proxy is installed.
This avoids breaking apt on fresh VMs.

### What `99-integration-tests.yml` validates

- SSH configuration security (ssh-audit)
- All K3S nodes Ready
- No pods in CrashLoopBackOff or Error (configurable exclusions)
- Cilium status healthy
- CoreDNS resolution working
- K3S API server responding
- SELinux active (permissive or enforcing)
- SELinux K3S file contexts applied
- Kopia repo status (if kopia_password defined)
- Kopia snapshot timer active (if configured)
- btrfs device stats clean (if backup_btrfs_enabled)
- kube-bench CIS benchmark (`k3s-cis-1.12`): full report with per-check status,
  threshold at 3 FAIL max (1.2.26 etcd-cafile inapplicable on kine unix socket +
  5.1.1 cluster-admin + 5.1.3 wildcards are inherent to third-party charts)

### What `98-firewall-audit.yml` validates

- UFW active with correct default policies (deny in, allow out)
- Expected ALLOW rules present per host group (SSH, K3S API, Cilium,
  etcd, HAProxy, WireGuard, MariaDB, DNS)
- No unexpected ALLOW rules
- nftables backend in use (not iptables legacy)

## Security audit

**Automated (in integration tests):**
- kube-bench `k3s-cis-1.12` — runs in `99-integration-tests.yml`, displays full report,
  asserts ≤ 3 FAIL.

**Manual (during maintenance):**
```sh
just audit-node ctrl.k3s.dev.local    # Full kube-bench output (all sections)
just audit-cluster                     # NSA/CISA + MITRE scan (kubescape)
```

## CI

| Stage | Environment | What |
|-------|-------------|------|
| PR check | GitHub Actions | Lint + ansible-lint + yamlfmt |
| Pre-release | Manual, Vagrant | Full integration tests |

## Multi-arch

The ARM cloud VPS is ARM64, bare-metal may be AMD64.
Vagrant tests one arch only (host arch). All tool roles support both
amd64 and arm64 via `ansible_architecture` detection.
