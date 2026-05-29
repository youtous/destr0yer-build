# Security Architecture Review

Decisions: [ADR-008](adr/008-network-zero-trust.md) (zero-trust),
[ADR-020](adr/020-namespace-templates.md) (namespace defaults),
[ADR-021](adr/021-kyverno-policy-engine.md) (Kyverno),
[ADR-025](adr/025-k8s-api-auth.md) (K8S API auth)

Last updated: 2026-05-28

## Current security posture

| Area | Implementation | Status |
|------|---------------|--------|
| Disk encryption for secrets | Ansible Vault (AES-256) + SOPS/age (K8S) | ✅ |
| K3S secrets-at-rest encryption | `secrets-encryption: true` | ✅ |
| K3S kernel hardening | `protect-kernel-defaults: true` | ✅ |
| SSH hardening | Dedicated role, WG-restricted IPs, ed25519 keys | ✅ |
| Host hardening | Modprobe, login_defs, limits, sysctl (CIS) | ✅ |
| fail2ban | Host-level, SSH + services | ✅ |
| UFW firewall | Host-level, restricted ports, `ufw_smart_rules`. Pod CIDR (`local_container_ips`) allowed on HAProxy ports — required because hostNetwork traffic traverses UFW. | ✅ |
| dnscrypt-proxy | Encrypted DNS on every host | ✅ |
| Cilium encryption | `encryption.enabled: true`, `nodeEncryption: true` | ✅ |
| Cilium socketLB | Host processes can reach NodePort services via eBPF | ✅ |
| WireGuard PTP mesh | Encrypted inter-node tunnels (ChaCha20-Poly1305) | ✅ |
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
- WireGuard inter-node mesh (ChaCha20-Poly1305, always-on)

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
| Admission | Kyverno | Policy violations | **Yes** (reject) | Real-time |
| Runtime syscalls | Tetragon | Shell, privesc, file writes | **Yes** (kill/deny) | Real-time |
| App-level | CrowdSec | Brute force, scanning, bots | **Yes** (ban IP) | Real-time |
| Host-level | fail2ban + CrowdSec bouncer | SSH brute force, nftables ban | **Yes** (ban IP) | Real-time |
| Version bumps | Renovate | Outdated images/charts/deps | No (PR-based) | Continuous |

Audit runs are ephemeral (terminal only, no persistent storage of findings).

## Zero-trust checklist

- [x] UFW: `default deny incoming` on all bare-metal nodes
- [x] SSH: restricted to known IPs + WG subnet (relay: bootstrap-then-lock, see below)
- [x] K3S API: bind to private IP (`bind-address` + `advertise-address`)
- [x] Cilium: default-deny in all namespaces
- [x] PSA: `restricted` profile enforced
- [x] Cilium encryption: all pod-to-pod traffic encrypted
- [x] WireGuard mesh: all infra nodes as peers
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

**Result:** public SSH never reaches the host. All access goes through the WireGuard
mesh. The cloud provider firewall is the gate; UFW is defense-in-depth.

**Recovery:** re-open tcp/22 in the cloud provider panel. Instant, no Ansible needed.
The SSH daemon and UFW rules are still configured and ready.

See `inventories/dev/host_vars/relay.sample.yml` for the inventory pattern.

### Remote admin access — WireGuard UDP pipe

When the admin is not on the local network, SSH to self-hosted nodes goes through
the relay as a **blind UDP forwarder** (DNAT). The admin authenticates directly on
ctrl via WireGuard cryptokey routing — the relay never sees cleartext.

**Architecture:**

```
Admin laptop (10.99.98.100)
  → WG tunnel to relay:41994 (UDP DNAT, relay is blind)
  → ctrl wg0 authenticates admin by public key
  → ctrl forwards to worker/internal nodes via wg0 mesh
```

**Triple protection (static IP admin):**

1. **Cloud provider FW** — UDP 41994 restricted to admin's static IP only.
   Port invisible to all other sources.
2. **WG crypto-stealth** — Without admin's private key, no handshake response.
   Port scan returns nothing (indistinguishable from closed).
3. **Ctrl peer verification** — IP `10.99.98.100` is cryptographically bound
   to admin's key via WG AllowedIPs. Cannot be spoofed.

**Trust model:**

- Relay: **zero-trust** — blind UDP pipe, no WG keys for admin, cannot decrypt
  or forge traffic. Even root on a compromised relay cannot inject valid WG packets.
- Ctrl: **trusted** — authenticates admin directly, routes to internal nodes.
- Workers: **trusted via ctrl** — same physical site, ctrl forwards honestly.

**Filtering on ctrl (defense-in-depth):**

- `wg-filter-relay` iptables: allow `tcp/22` from `10.99.98.100/32` only
- `ssh_entrypoints` (UFW): includes `10.99.98.100/32`
- `restrict_user_ssh_ips` (sshd): optional per-user IP restriction

**Scaling:**

- Add admin → new peer on ctrl wg0. Relay unchanged.
- Revoke admin → remove peer from ctrl wg0. Relay unchanged.
- Add internal node → already routed via ctrl mesh. Nothing extra.

See `inventories/dev/host_vars/relay.sample.yml` (DNAT rules, cloud FW)
and `inventories/dev/host_vars/host.sample.yml` (ctrl peer config).

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
