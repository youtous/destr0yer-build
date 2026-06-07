# Security Architecture Review

Decisions: [ADR-008](adr/008-network-zero-trust.md) (zero-trust),
[ADR-020](adr/020-namespace-templates.md) (namespace defaults),
[ADR-021](adr/021-kyverno-policy-engine.md) (Kyverno),
[ADR-025](adr/025-k8s-api-auth.md) (K8S API auth)

Last updated: 2026-06-07

## Current security posture

| Area | Implementation | Status |
|------|---------------|--------|
| Disk encryption for secrets | Ansible Vault (AES-256) + SOPS/age (K8S) | ✅ |
| K3S secrets-at-rest encryption | `secrets-encryption: true` | ✅ |
| K3S kernel hardening | `protect-kernel-defaults: true` | ✅ |
| SSH hardening | Dedicated role, WG-restricted IPs, ed25519 keys, `TCPKeepAlive no` | ✅ |
| Host hardening | Modprobe, login_defs (SHA-512 65536 rounds), limits, sysctl (CIS + Lynis) | ✅ |
| File permissions | Cron dirs 700, `grub.cfg` 400, `/root/.ssh` 700 | ✅ |
| Systemd sandboxing | Alloy, DNSCrypt, Monit, Fail2ban, Glances, Kopia hardened | ✅ |
| Lynis audit | Installed on all nodes, `just audit-lynis` (target ≥ 80/100) | ✅ |
| fail2ban | Host-level, SSH + services, `nftables-multiport` banaction | ✅ |
| UFW firewall | Host-level, restricted ports, `ufw_smart_rules`. Pod CIDR (`local_container_ips`) allowed on HAProxy ports — required because hostNetwork traffic traverses UFW. | ✅ |
| dnscrypt-proxy | Encrypted DNS on every host | ✅ |
| Cilium encryption | `encryption.enabled: true`, `nodeEncryption: true` | ✅ |
| Cilium socketLB | Host processes can reach NodePort services via eBPF | ✅ |
| WireGuard planes | Encrypted inter-node tunnels (4 planes, ChaCha20-Poly1305) | ✅ |
| Image pins | All images pinned by SHA256 digest | ✅ |
| Ansible roles pinned by SHA | Commit hash in `requirements.yml` | ✅ |
| Collections version-pinned | `requirements.yml` | ✅ |
| TLS on ingress | cert-manager internal CA + HAProxy | ✅ |
| HSTS + security headers | HAProxy config | ✅ |
| SELinux MAC | Permissive mode, K3S `selinux: true`, file contexts set | ✅ |
| K3S audit logging | `audit-log-path` + policy, shipped to Loki via Alloy | ✅ |
| PSA restricted | Enforced for all namespaces (except kube-system, cilium, openebs) | ✅ |
| Default-deny NetworkPolicy | Cilium per-namespace policies | ✅ |
| Kyverno admission | Digest-only images, resource limits, registry allowlist | ✅ |
| CrowdSec LAPI | K8S-level threat detection | ✅ |
| CrowdSec nftables bouncer | Host-level IP banning via LAPI NodePort | ✅ |
| Velero FSB encryption | Kopia AES-256-GCM (custom password in SOPS) | ✅ |
| Authelia SSO | OIDC for Grafana/Seafile, forward auth for other services | ✅ |
| Service-node-port-range | Restricted to `1024-16000` | ✅ |
| Renovate | Automated dependency updates via GitHub App | ✅ |
| User namespaces | Kyverno mutates `hostUsers: false` (container root → unprivileged host UID) | ✅ |
| Container patching | DMS `user-patches.sh` runs apt upgrade on start + weekly CronJob restart | ✅ |
| CIS file permissions | systemd timer `k3s-harden-permissions` (30s after boot + every 6h): PKI 600, CNI 600 + root:root | ✅ |
| CIS default SA hardening | Playbook patches all `default` SAs with `automountServiceAccountToken: false` | ✅ |
| CIS SA token restriction | Kyverno `disable-automount-sa-token` mutates pods to disable token automount | ✅ |
| CIS default SA validation | Kyverno `restrict-default-service-account` blocks pods using SA `default` | ✅ |
| kube-bench CIS k3s-cis-1.12 | Automated in integration tests, threshold ≤ 3 FAIL (1.2.26 + 5.1.1 + 5.1.3 inherent) | ✅ |

### CIS 1.2.26 — `--etcd-cafile` (accepted FAIL)

CIS 1.2.26 requires `--etcd-cafile` on the kube-apiserver to verify the etcd
server certificate via TLS. K3S with embedded kine/SQLite does **not** set this
flag, and it **must not be set manually** via `kube-apiserver-arg`:

1. K3S uses kine/SQLite over a local unix socket (`unix://kine.sock`), not a TCP
   etcd cluster. There is no network path to eavesdrop — TLS is irrelevant.
2. Adding `etcd-cafile` manually causes the apiserver to fail with
   `error creating storage factory: context deadline exceeded` — a fatal crash
   loop that prevents the cluster from starting (tested on K3S v1.36.1+k3s1).
3. The kine data never leaves the host; disk encryption (secrets-at-rest) and
   filesystem permissions protect it at rest.

kube-bench reports CIS 1.2.26 as FAIL — this is an accepted false positive.
The kube-bench threshold accounts for it (see below).

## Intra-cluster encryption

All pod-to-pod traffic encrypted at kernel level by Cilium. Internal services
use `http://` at the application layer — Cilium transparently encrypts the
underlying network packets. Adding application-level TLS on top would be
double-encryption with no security gain on a single-node cluster.

**Exceptions (TLS at application layer):**
- External ingress (HAProxy → cert-manager TLS termination)
- SMTP to external mailserver (TLS enforced in prod, disabled in dev for Mailpit)
- WireGuard inter-node planes (ChaCha20-Poly1305, always-on)

**Dev-only TLS relaxations** (in `kluctl/targets/dev.yaml`):
- `authelia_smtp_disable_require_tls: true` — Mailpit has no TLS
- `authelia_smtp_disable_starttls: true`
- `authelia_smtp_tls_skip_verify: true`
- Alertmanager `smtp_require_tls: false`

These are overridden by prod defaults (TLS enforced).

## Network policies — egress matrix

Internet access restricted to 3 components:

| Policy | Scope |
|--------|-------|
| `default-deny` | All ingress/egress denied by default |
| `allow-dns` | Egress to CoreDNS (port 53 UDP/TCP) |
| `allow-ingress` | Ingress from HAProxy controller |
| `allow-monitoring` | Ingress from Prometheus + Prometheus egress |
| `allow-cluster-internal` | Egress to cluster entity only |
| `allow-haproxy-egress` | HAProxy egress to all cluster backends |
| `allow-certmanager-cluster` | cert-manager egress to K8S API |
| `allow-internet-registry` | Registry → docker.io, ghcr.io, quay.io (FQDN-locked) |
| `allow-internet-mail` | Mailserver SMTP outbound (ports 25, 465, 587) |
| `allow-internet-crowdsec` | CrowdSec → hub/api.crowdsec.net (FQDN-locked) |
| `allow-internet-certmanager` | cert-manager → Let's Encrypt/deSEC (conditional) |
| `allow-internet-seafile` | Seafile → Authelia OIDC discovery |
| `restrict-mail-ingress` | Mailserver: only HAProxy on ports 25/465/993 |

See `kluctl/security/network-policies/README.md` for the full matrix.

## Authentication architecture

**Dual-mode** controlled by `auth_mode` target arg:

| Mode | Mechanism | Use case |
|------|-----------|----------|
| `authelia` | HAProxy forward auth → Authelia SSO | Default |
| `basic` | HAProxy basic-auth annotations | Clusters without Authelia |

**Service protection matrix:**

| Service | Auth method | Access |
|---------|------------|--------|
| Grafana | OIDC via Authelia | Mesh / ingress |
| Garage admin API | Internal only (`just garage`) | Not exposed |
| Whoami | Forward auth (Authelia) | Ingress |
| Seafile | OIDC via Authelia | Ingress |
| Home Assistant | Native auth | Ingress |
| Authelia | Self-managed | Ingress |
| Loki / Prometheus | Internal ClusterIP only | Not exposed |

## CrowdSec — dual-layer threat detection

```
K8S level (LAPI + agent)              Host level (nftables bouncer)
┌──────────────────────────┐          ┌──────────────────────────┐
│ CrowdSec LAPI            │          │ crowdsec-firewall-bouncer│
│  ├── parsers             │◄─────────│  connects to LAPI via    │
│  ├── scenarios           │ NodePort │  socketLB (eBPF)         │
│  └── decisions           │          │  bans IPs in nftables    │
│       │                  │          └──────────────────────────┘
│       ▼                  │
│ HAProxy SPOA bouncer     │
│  blocks at ingress (L7)  │
└──────────────────────────┘
       │
       ▼
Community blocklists
(shared threat intelligence)
```

Host-level fail2ban stays for SSH (safety net). CrowdSec handles application/K8S level.

## Runtime threat detection — Tetragon

Tetragon (eBPF, Cilium project) deployed via Kluctl `security/tetragon/`.
Default TracingPolicies:
- File writes to `/etc/passwd`, `/etc/shadow`, `/etc/sudoers`
- Unexpected shell execution in containers
- Privilege escalation attempts (`setuid`, `setgid`)
- Unexpected network connections

Events shipped to Loki via Alloy for alerting in Grafana.

## Security tool stack

| Layer | Tool | Detects | Enforces | Frequency |
|-------|------|---------|----------|-----------|
| Node config | kube-bench | CIS misconfigurations | No | Maintenance |
| Workload config | kubescape | NSA/CISA/MITRE gaps | No | Maintenance |
| Host hardening | Lynis | SSH, PAM, kernel, filesystem, firewall gaps | No | Maintenance |
| Systemd sandboxing | `systemd-analyze security` | Missing service restrictions | No | Maintenance |
| Admission | Kyverno | Policy violations | **Yes** (reject) | Real-time |
| Runtime syscalls | Tetragon | Shell, privesc, file writes | **Yes** (kill/deny) | Real-time |
| App-level | CrowdSec | Brute force, scanning, bots | **Yes** (ban IP) | Real-time |
| Host-level | fail2ban + CrowdSec bouncer | SSH brute force, nftables ban | **Yes** (ban IP) | Real-time |
| Version bumps | Renovate | Outdated images/charts/deps | No (PR-based) | Continuous |

Audit runs are ephemeral (terminal only, no persistent storage of findings).

### Audit commands

```sh
# K3S CIS benchmark (per-node)
just audit-node ctrl.k3s.dev.local

# K8S workload audit (cluster-wide)
just audit-cluster

# Host-level security audit with Lynis (per-node)
just audit-lynis ctrl.k3s.dev.local

# Systemd service hardening scores (per-node, shows non-OK services only)
just audit-systemd ctrl.k3s.dev.local
```

**Lynis** audits SSH config, PAM, kernel parameters, filesystem permissions,
firewall rules, and more. Score is out of 100 — target ≥ 80. Installed via
`system_packages` on all nodes.

**systemd-analyze security** scores each service from 0 (safe) to 10 (exposed).
Services we control should target ≤ 5.0 (MEDIUM or better). System services
(ssh, cron, dbus) cannot be hardened without breaking functionality.

## Zero-trust checklist

- [x] UFW: `default deny incoming` on all bare-metal nodes
- [x] SSH: restricted to known IPs + WG subnet (relay: bootstrap-then-lock, see below)
- [x] K3S API: bind to private IP (`bind-address` + `advertise-address`)
- [x] Cilium: default-deny in all namespaces
- [x] PSA: `restricted` profile enforced
- [x] Cilium encryption: all pod-to-pod traffic encrypted
- [x] WireGuard planes: per-plane isolation (admin, infra-ext, infra-int, relay-admin)
- [x] CrowdSec nftables bouncer: host-level IP banning
- [x] Kopia SFTP: restricted to WG subnet
- [ ] Relay node UFW: allow public ports from `0.0.0.0/0` only (prod)
- [ ] SELinux enforcing mode (currently permissive)
- [ ] LUKS encryption on relay node boot volume

### SSH bootstrap-then-lock (relay)

The relay is the only node with a public IP. SSH uses a two-phase pattern:

1. **Bootstrap** — Cloud provider firewall allows tcp/22 from admin IP.
   `ssh_entrypoints` in inventory lists both admin IP and WG subnet (defense-in-depth
   at UFW level). Run `just provision` + `just configure` to establish WireGuard.

2. **Locked** — Verify WG connectivity (`ssh walle@<relay-wg-ip>`), then close tcp/22
   in the cloud provider firewall (panel, API, or Terraform). No Ansible re-run needed.
   Inventory stays unchanged — UFW `ssh_entrypoints` remains as a second layer.

**Result:** public SSH never reaches the host. All access goes through WireGuard
planes (`wg-relay-admin` for relay, `wg-admin` for clusters). The cloud provider
firewall is the gate; UFW is defense-in-depth.

**Recovery:** re-open tcp/22 in the cloud provider panel. Instant, no Ansible needed.
The SSH daemon and UFW rules are still configured and ready.

See `inventories/dev/host_vars/relay.sample/main.yml` for the inventory pattern.

### Remote admin access — WireGuard planes

Remote admin access uses **dedicated WireGuard planes**, separated from service
traffic. Full topology and interface listing in
[networking.md](networking.md#wireguard-plane-separation).

```
                               ┌─────────────────────────┐
  wg-relay-admin :41995       │                         │
  ┌──────────────────────────►│        RELAY            │
  │  (SSH to relay only)      │                         │
  │                           │  wg-relay-admin :41995  │
  │  wg-admin :41994          │  wg-infra-ext   :41993  │
  │  ┌───────────────────────►│  DNAT :41994 ──────┐    │
  │  │  (relay = blind DNAT)  └────────────┬───────┼────┘
  │  │                                     │       │
  │  │                          wg-infra-ext       │ DNAT via
  │  │                          (services)         │ wg-infra-ext
  │  │                                     │       │
┌─┴──┴──────────┐               ┌──────────┴───────┴───┐
│               │               │       CTRL           │
│   Admin PC    │               │                      │
│               │               │  wg-admin     :41994 │
│               │               │  wg-infra-ext :41993 │
│               │               │  wg-infra-int :41991 │
└───┬───────────┘               └──────────┬───────────┘
    │                                      │
    │                           wg-infra-int (inter-cluster)
    │                                      │
    │  wg-admin :41994          ┌──────────┴───────────┐
    │  (direct, fixed IP)       │       DC2            │
    └──────────────────────────►│                      │
                                │  wg-admin     :41994 │
                                │  wg-infra-int :41991 │
                                └──────────────────────┘
```

**Admin access flow (cluster behind relay — no fixed IP):**

1. Admin laptop opens WG tunnel to `relay:41994`
2. Relay receives opaque UDP — it has no key to decrypt, just DNATs to `ctrl:41994`
3. Ctrl's `wg-admin` interface decrypts — authenticates admin by cryptokey
4. Admin has SSH/kubectl access to ctrl

**Admin access flow (cluster with fixed IP):**

1. Admin laptop opens WG tunnel directly to `dc2:41994`
2. DC2's `wg-admin` interface decrypts — authenticates admin by cryptokey
3. Admin has SSH/kubectl access to DC2. No relay involved.

### WireGuard plane isolation

Each plane has independent keys. Compromising one plane does not expose the others.

| Plane | Port | Relay role | Compromission does NOT expose |
|-------|------|-----------|-------------------------------|
| `wg-relay-admin` | 41995 | Terminates (decrypts) | Clusters (admin or services) |
| `wg-admin` | 41994 | Blind DNAT (cannot decrypt) | Service traffic, inter-cluster |
| `wg-infra-ext` | 41993 | Terminates (decrypts) | Admin access, inter-cluster |
| `wg-infra-int` | 41991 | N/A (no relay) | Admin access, public services |

**Why not combine `wg-relay-admin` and `wg-admin`?** The relay is the most
exposed node (public IP, open ports). If combined, a compromised relay could
impersonate the admin to ctrl (it would hold the WG keys). Separated: a
compromised relay gives SSH to the relay only, never to any cluster.

**Triple protection (static IP admin):**

1. **Cloud provider FW** — UDP 41994 restricted to admin's static IP only.
   Port invisible to all other sources.
2. **WG crypto-stealth** — Without admin's private key, no handshake response.
   Port scan returns nothing (indistinguishable from closed).
3. **Ctrl peer verification** — admin IP is cryptographically bound to admin's
   key via WG AllowedIPs. Cannot be spoofed.

**Trust model:**

- Relay: **zero-trust** — blind UDP pipe for admin, no WG keys for `wg-admin`.
  Even root on a compromised relay cannot inject valid WG packets.
- Ctrl: **trusted** — authenticates admin directly via `wg-admin` interface.
- Workers: **trusted via Cilium** — same physical site, encrypted eBPF mesh.

**Filtering on ctrl (defense-in-depth):**

- `wg-admin` iptables chain: allow `tcp/22` from admin WG subnet only
- `ssh_entrypoints` (UFW): includes admin WG subnet
- `restrict_user_ssh_ips` (sshd): optional per-user IP restriction

**Scaling:**

- Add admin → new peer on each cluster's `wg-admin`. Relay unchanged.
- Revoke admin → remove peer. Relay unchanged.
- Add cluster → admin adds a new WG peer (direct or via DNAT). Independent keys.
- Add site → new `wg-infra-int` peer on each cluster ctrl. Admin plane unchanged.

See [`inventories/dev/host_vars/relay.sample/`](../inventories/dev/host_vars/relay.sample/)
(DNAT rules, cloud FW) and [`inventories/dev/host_vars/host.sample/`](../inventories/dev/host_vars/host.sample/)
(ctrl peer config).

## Mail workload isolation

Attack surface: internet-facing SMTP/IMAP via HAProxy relay → K3S mailserver pod.

**Defense-in-depth layers:**

| Layer | Control | Mitigates |
|-------|---------|-----------|
| Network | `restrict-mail-ingress` CiliumNetworkPolicy | Lateral movement from other pods |
| Network | HAProxy `config-tcp` ACL on port 4190 | ManageSieve restricted to trusted_cidrs only |
| Network | WireGuard `wg-filter-relay` iptables chain | Only relay can reach mail NodePorts |
| Admission | Kyverno `default-user-namespaces` (`hostUsers: false`) | Container escape → unprivileged host UID |
| Admission | PSA restricted | No privileged, no hostPath, no hostPID |
| Runtime | Tetragon TracingPolicy | Shell exec, privesc, unexpected network |
| Runtime | Pod memory limits (1024Mi) | DoS via CVE-2026-27857 capped |
| Patching | `user-patches.sh` apt upgrade on every start | Debian backported CVE fixes |
| Patching | CronJob `mailserver-restart` (weekly Mon 04:00 UTC) | Forces patch application without deploy |
| Image | Pinned by SHA256 digest, Renovate watches upstream | No silent tag mutation |

**Residual risk:** DMS 15.1.0 ships Dovecot 2.3.19. CVE-2026-27857/27858 are DoS-only
(memory exhaustion), require authenticated IMAP, and are capped by pod memory limits.
Full fix arrives with DMS v16 (Debian 13 base, Dovecot 2.4.x).

## Remaining gaps

| # | Gap | Severity | Action |
|---|-----|----------|--------|
| 1 | SELinux permissive | Medium | Collect AVCs, build custom policy, switch to enforcing |
| 2 | No image scanning in CI | Low | Add Trivy scan to GitHub Actions (Renovate covers version bumps) |
| 3 | Expired Helm GPG keys | Low | Update keys or switch to SHA256 checksum verification |
| 4 | Relay at-rest data | Low | LUKS encryption on relay boot volume |
| 5 | Let's Encrypt (prod) | Medium | deSEC delegation + cert-manager ClusterIssuer (ADR-024) |
