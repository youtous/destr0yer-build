# ADR-038: SFTPGo — fine-grained SFTP server with S3 backend

**Status**: TODO

**Context**: Kopia currently pushes backups to the backup node via raw OpenSSH
SFTP (`backup_storage` role). All backup clients connect as separate SSH users
chrootjailed to `backup_root_directory`, but the server offers no per-user
quota, no audit trail beyond sshd logs, no virtual folder mapping, and no
ability to route storage to an S3-compatible backend.

Limitations of the current setup:
- **Single backend**: Everything goes to the local btrfs filesystem. Moving
  cold backups to S3 (Garage) requires a separate cron + `rclone` pipeline.
- **No per-user isolation at storage level**: chroot + POSIX permissions work
  but are coarse — no per-user quota enforcement, no bandwidth limits.
- **No granular audit**: `sshd` logs connections but not individual file
  operations (upload, delete, rename).
- **No web management**: User/key management is Ansible-only (fine for IaC,
  but no operational visibility).

**Decision**: Replace raw OpenSSH SFTP with [SFTPGo](https://github.com/drakkan/sftpgo)
(AGPLv3, Go) on the backup node for backup ingestion.

**Why SFTPGo**:

| Feature | OpenSSH SFTP | SFTPGo |
|---------|-------------|--------|
| Storage backends | Local FS only | Local, S3, GCS, Azure, encrypted FS |
| Per-user virtual folders | No (chroot only) | Yes (map user → path or S3 prefix) |
| Quotas | No | Per-user upload/download/storage quotas |
| Bandwidth limits | No | Per-user rate limiting |
| Audit logging | sshd logs only | Structured JSON logs (per-operation) |
| Web admin | No | Built-in WebAdmin UI |
| PROXY protocol | No | v1/v2 (behind HAProxy) |
| Event hooks | No | Webhooks / scripts on upload/download/delete |
| Authentication | SSH keys | SSH keys, passwords, OIDC, LDAP |
| Data-at-rest encryption | No (rely on LUKS) | Built-in encrypted FS backend |
| License | BSD | AGPLv3 (community edition, fully functional) |

**Deployment modes**: Two options, same SFTPGo config — deploy where it makes
sense for the topology.

### Option A — Bare-metal (Ansible role)

Backup node runs SFTPGo as a systemd service. Best for dedicated backup
nodes outside K3S (no dependency on the cluster being healthy).

```
K3S nodes / Podman hosts                    Backup node (bare-metal)
┌──────────────────────┐                    ┌──────────────────────────┐
│                      │                    │ SFTPGo (systemd)         │
│ kopia backup         │                    │                          │
│   └─► SFTP ──────────┼── WireGuard ──────►│ user: ctrl               │
│                      │                    │   └─► /backups/ctrl/     │
│                      │                    │       (local btrfs)      │
└──────────────────────┘                    │                          │
                                            │ user: cold-archive       │
                                            │   └─► s3://garage/cold/  │
                                            │       (Garage S3)        │
                                            │                          │
                                            │ btrfs snapshots (local)  │
                                            │ Structured audit logs    │
                                            └──────────────────────────┘
```

### Option B — Kubernetes (Kluctl component)

SFTPGo runs as a K8S Deployment in a dedicated `sftpgo` namespace. Best for
multi-tenant clusters where backup ingestion is a cluster service (e.g.
Velero S3 target, in-cluster SFTP for app data export).

```
In-cluster clients                          sftpgo namespace
┌──────────────────────┐                    ┌──────────────────────────┐
│ Velero / CronJobs    │                    │ Deployment: sftpgo       │
│   └─► SFTP/S3 ───────┼── ClusterIP ─────►│   PVC: config + data     │
│                      │                    │   Secret: s3-credentials │
└──────────────────────┘                    │   Secret: ssh-host-keys  │
                                            │                          │
External clients                            │ Service: sftpgo (SFTP)   │
┌──────────────────────┐                    │ Service: sftpgo-web      │
│ kopia (remote host)  │                    │   (WebAdmin, optional)   │
│   └─► SFTP ──────────┼── HAProxy TCP ───►│                          │
│                      │   (PROXY proto v2) │ ServiceMonitor (metrics) │
└──────────────────────┘                    └──────────────────────────┘
```

**Key design choices**:

1. **Kopia clients unchanged** — Kopia connects via SFTP, no client-side
   change needed. SFTPGo is a drop-in replacement for OpenSSH SFTP.
2. **Mixed backends per user** — Hot backups stay on local btrfs (fast,
   snapshottable). Cold archives and Velero data can route to Garage S3
   via SFTPGo virtual folders.
3. **SSH key auth stays** — Existing Ansible-managed SSH keys work as-is.
   SFTPGo supports the same `authorized_keys` format.
4. **OpenSSH SFTP subsystem disabled** — Once SFTPGo is active, disable
   the SFTP subsystem in `sshd_config` to avoid port conflict (SFTPGo
   listens on its own port, or takes over port 22 for SFTP).
5. **Quotas per backup client** — Prevent a single node from filling the
   entire backup volume.
6. **Event hooks for alerting** — SFTPGo can call a webhook or script on
   failed uploads, quota exceeded, etc. Feeds into existing ntfy/email
   alerting pipeline.

**Exposure model**:

Three protocols to expose, each with different constraints:

| Protocol | Port | Nature | Consumers |
|----------|------|--------|-----------|
| SFTP (SSH) | 2222 (configurable) | TCP, encrypted natively | Kopia clients (remote hosts), scripts |
| WebAdmin | 8080 | HTTP | Operators (browser) |
| Prometheus metrics | 8081 | HTTP | Prometheus scraper |

Options for SFTP exposure (K8S deployment):

| | HAProxy TCP frontend | NodePort | WireGuard only |
|---|---------------------|----------|----------------|
| **How** | HAProxy binds host port, proxies to SFTPGo Service (same as mail ports 25/465/587/993) | K8S NodePort on each node, SFTPGo directly reachable | No K8S exposure — clients connect via WG mesh to bare-metal instance |
| **PROXY protocol** | Yes (v2) — real client IP preserved in SFTPGo audit logs | No — SFTPGo sees node IP only | N/A (direct connection) |
| **CrowdSec** | Yes — SPOA bouncer can inspect TCP connections (brute-force ban) | No — bypasses HAProxy entirely | N/A |
| **Centralized ACL** | Yes — HAProxy `tcp-request connection reject` with trusted_cidrs | Partial — UFW/CiliumNetworkPolicy only | Full — WG key = auth |
| **Complexity** | Low — existing pattern (`controller.tcp` in helm-values) | Low | None (K8S not involved) |
| **Backup traffic impact** | Minimal — HAProxy TCP passthrough is near-zero overhead | None | None |

**Recommendation**: Same pattern as mail — **HAProxy TCP frontend** for external
SFTP access.

- Consistent with existing architecture (mail ports already use this)
- CrowdSec protection against SSH brute-force on SFTP port
- PROXY protocol v2 preserves client IP for audit (SFTPGo supports it
  natively via `sftpd.proxy_protocol` = 2)
- Conditional `expect-proxy` possible (same pattern as `mail_relay_wg_ip`):
  trust PROXY headers from WG relay IP only

For **in-cluster** consumers (Velero, CronJobs): plain ClusterIP Service,
no HAProxy, no PROXY protocol.

For **bare-metal** deployment: SFTPGo listens directly on the SFTP port.
Default: WireGuard-only (zero public ports, per ADR-008). Exception below.

**Exposure model — WG first, public SFTP as documented exception**:

The general principle (ADR-008) is: zero public ports on bare-metal, all
traffic through WireGuard. SFTPGo is the **only service** where public
exposure without VPN can be considered, because the protocol itself provides
sufficient defense in depth:

| Defense layer | What it does |
|---------------|-------------|
| SSH protocol | Natively encrypted transport, no plaintext phase (unlike STARTTLS) |
| SSH key-only auth | Password auth disabled in SFTPGo — immune to credential stuffing/brute-force of passwords |
| CrowdSec | Bans IPs after N failed SSH handshakes (custom scenario or SFTPGo event hooks) |
| CryptFS at-rest | Even if the server is compromised, stored backup data is encrypted per-user |
| Kopia client-side encryption | Backup blobs are already ciphertext before reaching SFTPGo |
| Per-user permissions | Write + list only, no delete — limits blast radius of a compromised key |
| Structured audit | Every operation logged to Loki — immediate visibility on anomalies |

**Prerequisite for public exposure**: the node must have a **fixed public IP**.
Dynamic IPs require DDNS, which adds fragility and attack surface (DNS
poisoning). With a fixed IP, clients configure the endpoint once and UFW
can allowlist known source IPs.

Two paths depending on topology:

| | Path A — Via cloud relay (preferred) | Path B — Direct on node |
|---|--------------------------------------|------------------------|
| **When** | Node is behind NAT or has no public IP, relay exists | Node has a fixed public IP, no relay needed |
| **How** | Relay DNAT port 2222 → ctrl via `wg-infra-ext` (blind, no termination — same pattern as mail/SSH in ADR-006/008) | SFTPGo binds on public interface, UFW allows port 2222 from `0.0.0.0/0` or known source IPs |
| **ADR-008 compliance** | Fully compliant — relay is the only node with public ports | **Documented exception** — bare-metal node opens one public port |
| **CrowdSec** | On relay (nftables bouncer) + on HAProxy (SPOA) | On node (nftables bouncer) + SFTPGo event hooks |
| **PROXY protocol** | Yes (relay → HAProxy → SFTPGo) | No (direct connection, SFTPGo sees real IP natively) |
| **Complexity** | Requires relay + WG tunnel | Simplest — one UFW rule + SFTPGo listen |

**What is NEVER exposed publicly** (regardless of path):
- WebAdmin (always VPN-only: WG interface or HAProxy Ingress behind Authelia)
- Prometheus metrics (internal scraping only)
- SFTPGo REST API (localhost or WG-only)

**Configuration** — Ansible variables control the exposure mode:
```yaml
# Default: WG-only (zero public exposure, ADR-008 compliant)
sftpgo_public_sftp: false

# Exception: expose SFTP publicly (requires fixed public IP)
sftpgo_public_sftp: true
sftpgo_sftp_listen: "0.0.0.0"       # or specific public interface IP
sftpgo_sftp_allowed_ips: []          # empty = any, or list of known source CIDRs
```

WebAdmin exposure (both deployments, always VPN-gated):
- K8S: standard HAProxy Ingress (HTTPS, behind Authelia if `auth_mode=authelia`)
- Bare-metal: bind to WireGuard interface only (`127.0.0.1` or WG IP),
  reverse-proxied via nginx/caddy if needed

Prometheus metrics: scraped via ServiceMonitor (K8S) or Alloy
`prometheus.scrape` (bare-metal). Never publicly exposed.

```
Path A — Via relay (WG first, default)

External backup client           Cloud relay              HAProxy (ctrl)         sftpgo
┌──────────────────┐            ┌──────────────┐        ┌──────────────┐       ┌────────┐
│ kopia / NAS       │            │ DNAT :2222   │        │ TCP frontend │       │        │
│  └─► relay IP ───┼───────────►│  ──► wg-ext ─┼───────►│  :2222       ┼──────►│ :2222  │
│                   │            │ nftables+CS   │        │ PROXY v2+CS  │       │        │
└──────────────────┘            └──────────────┘        └──────────────┘       └────────┘

Path B — Direct (fixed public IP, documented exception to ADR-008)

External backup client                                     Bare-metal node
┌──────────────────┐                                      ┌─────────────────┐
│ kopia / NAS       │                                      │ SFTPGo :2222    │
│  └─► node IP ────┼─────────────────────────────────────►│ UFW allow 2222  │
│                   │                                      │ CrowdSec host   │
└──────────────────┘                                      │ SSH key auth    │
                                                          └─────────────────┘

WG client (standard, all topologies)

WG backup client             HAProxy (K8S) or SFTPGo (bare-metal)
┌──────────────────┐        ┌─────────────────┐
│ kopia             │        │                 │
│  └─► WG IP ──────┼───────►│ svc/sftpgo:2222 │
└──────────────────┘        └─────────────────┘

In-cluster consumer (K8S only, no HAProxy)
┌──────────────────┐        ┌─────────────────┐
│ Velero CronJob   │        │                 │
│  └─► ClusterIP ──┼───────►│ svc/sftpgo:2222 │
└──────────────────┘        └─────────────────┘

Operator (always VPN)
┌──────────────────┐        ┌─────────────────┐
│ browser ─── WG ──┼───────►│ sftpgo.k8s.home │
└──────────────────┘        │ Authelia gated   │
                            └─────────────────┘
```

**Encryption** — two layers, both enabled:

| Layer | What | Algorithm | Scope |
|-------|------|-----------|-------|
| **In-transit** | SSH protocol (SFTP) | ChaCha20-Poly1305 / AES-256-GCM (negotiated per SSH session) | All data between client and SFTPGo |
| **At-rest (CryptFS)** | Transparent disk encryption | DARE format (AES-256-GCM or ChaCha20-Poly1305 via minio/sio) | All files stored on local filesystem |

**CryptFS** (data-at-rest encryption):
- Transparent to clients — they transfer plain data, SFTPGo encrypts/decrypts
  on-the-fly during upload/download. No client-side change needed.
- Per-user passphrase, stored encrypted via SFTPGo's KMS (NaCl secret box
  with master key, or external KMS).
- Per-file encryption keys derived from the passphrase (HKDF).
- Protects against: physical disk theft, backup media compromise, unauthorized
  access to raw filesystem (even root on the host sees only ciphertext).
- Limitations: no upload resume, no truncate, no `sshfs` mount. Acceptable
  for backup workloads (Kopia does full-file uploads).

**KMS master key**: Required for encrypting user passphrases in SFTPGo's
database. Stored as a SOPS-encrypted secret (`sftpgo_kms_master_key` in
`targets/<env>.enc.yaml`). Without this key, SFTPGo cannot decrypt user
credentials — treat as critical secret alongside LUKS keys.

Configuration:
```json
{
  "kms": {
    "secrets": {
      "master_key_path": "/run/secrets/sftpgo-kms-master-key"
    }
  }
}
```

Combined with LUKS on the underlying block device (existing pattern), this
gives three encryption layers: LUKS (block) → CryptFS (file) → SSH (transit).
Belt-and-suspenders: even if LUKS is compromised or the volume is mounted
without LUKS (e.g. forensic access), CryptFS keeps backup data encrypted.

For **S3 backends** (Garage): CryptFS is not supported by SFTPGo on
non-local backends (S3, GCS, Azure) — it operates at the filesystem I/O
level and cannot intercept S3 API calls. This is a SFTPGo limitation, not
a choice. Mitigation: Kopia encrypts its repository blobs client-side
(AES-256 or ChaCha20) before upload, so SFTPGo only ever receives
ciphertext. Additionally, Garage supports server-side encryption (SSE).
Net result: S3-stored data is encrypted at two levels (Kopia client-side +
Garage SSE) even without CryptFS.

**S3 backend specifics** (Garage):
- SFTPGo maps a virtual folder to `s3://bucket/prefix/` with
  `force_path_style: true` (required for Garage).
- Garage admin token stays in `garage` namespace — bucket/key provisioning
  is manual (existing pattern, see ADR-012).
- S3 limitations apply: no `chmod`/`chown`/`symlink` (not needed for
  backup blobs — Kopia uses flat files).

**Security integration** (K8S deployment):

| Layer | Measure |
|-------|---------|
| **PSA** | `sftpgo` namespace uses `restricted` enforcement (default). SFTPGo runs as non-root, no privileged caps needed. |
| **CiliumNetworkPolicy** | Default-deny (existing pattern). Explicit allow rules: ingress SFTP port from trusted CIDRs / backup source pods, egress to Garage S3 endpoint (`garage.garage.svc`), egress DNS. WebAdmin ingress from `haproxy-ingress` namespace only. |
| **Kyverno** | Standard policies apply (image digest pinning, no `latest`, resource limits, no hostPath). No exemptions expected. |
| **Secrets** | S3 access key + SFTP host keys stored in `kind: Secret` (SOPS-encrypted in `targets/<env>.enc.yaml`). Zero plaintext rule applies. |
| **PROXY protocol** | SFTPGo supports PROXY protocol v1/v2 — enables real client IP logging when fronted by HAProxy TCP. Configured via `sftpd.proxy_protocol` in `sftpgo.json`. |
| **TLS** | WebAdmin/WebClient served behind HAProxy Ingress with TLS termination (cert-manager). SFTP is natively encrypted (SSH protocol). |
| **Audit** | Structured JSON logs shipped to Loki via Alloy sidecar or pod log collection. Per-operation visibility (login, upload, delete, quota exceeded). |
| **UFW** (bare-metal) | SFTP port managed by `sftpgo` role via `ufw_smart_rules` (self-contained, per convention). |

**Authentication and access control**:
- SSH key auth (primary): same keys as current `backup_users`, managed by
  Ansible. SFTPGo stores public keys in its user DB (JSON or embedded
  SQLite/bolt).
- OIDC (optional): WebAdmin can use Authelia as OIDC provider for
  operator access to the management UI.
- Per-user permissions: read-only, write-only, or full — virtual folders
  can restrict operations (e.g. backup clients = write + list, no delete).

**Migration path**:
1. Deploy SFTPGo on backup node (new Ansible role `sftpgo`)
2. Create SFTPGo users matching existing `backup_users`
3. Point SFTPGo at same `backup_root_directory` (btrfs)
4. Switch Kopia to connect to SFTPGo port (or keep port 22 if SFTPGo
   takes over SFTP)
5. Validate: backup + restore cycle
6. Disable OpenSSH SFTP subsystem
7. Add S3 virtual folders for cold/Velero (optional, after Garage
   multi-site — see ADR-012)
8. Deploy K8S variant (Kluctl component) for in-cluster use cases

**Implementation**:

Ansible (bare-metal):
- [ ] Create Ansible role `sftpgo` (install binary, systemd unit,
      config template, user provisioning)
- [ ] Migrate `backup_users` from `backup_storage` to SFTPGo user DB
- [ ] Configure per-user quotas and bandwidth limits
- [ ] UFW rules via `ufw_smart_rules`: WG-only by default,
      conditional public port when `sftpgo_public_sftp: true`
- [ ] Disable password auth in SFTPGo (`password_authentication: false`)
- [ ] Enable structured audit logging → Alloy → Loki

Kluctl (K8S):
- [ ] Create Kluctl component `storage/sftpgo` (Deployment, Service,
      PVC, Secrets, ConfigMap for `sftpgo.json`)
- [ ] Add `sftpgo` to `infra_namespaces` (default-deny, DNS, monitoring
      policies apply automatically)
- [ ] CiliumNetworkPolicy: allow ingress SFTP from trusted sources,
      egress to Garage S3 + DNS
- [ ] HAProxy TCP frontend for external SFTP (add to `controller.tcp`
      in helm-values, PROXY protocol v2, CrowdSec SPOA)
- [ ] Conditional `expect-proxy` for relay/WG source IPs (same pattern
      as `mail_relay_wg_ip`)
- [ ] Ingress for WebAdmin (optional, behind Authelia)
- [ ] ServiceMonitor for Prometheus metrics scraping
- [ ] Kluctl args: `enable_sftpgo`, `sftpgo_sftp_port` (default 2222)

Shared:
- [ ] Add S3 backend virtual folders (Garage)
- [ ] Update `kopia` role: point SFTP at SFTPGo port if different
- [ ] Enable CryptFS for all backup users (local filesystem backend)
- [ ] Generate and store KMS master key in SOPS secrets
- [ ] Generate per-user CryptFS passphrases in SOPS secrets
- [ ] Validate full backup/restore cycle (both deployments)
- [ ] Grafana dashboard for SFTPGo metrics + audit logs

Public SFTP exposure (when `sftpgo_public_sftp: true`):
- [ ] UFW rule for public SFTP port (conditional on `sftpgo_public_sftp`)
- [ ] CrowdSec custom scenario for SFTP brute-force detection
- [ ] Relay DNAT rule for Path A (port 2222 → ctrl via `wg-infra-ext`)
- [ ] Document ADR-008 exception in security.md

**Version**: SFTPGo v2.7.1 (latest as of 2026-03, AGPLv3 community edition)

**Risks**:
- **AGPLv3 license**: Acceptable for self-hosted infrastructure (no
  SaaS distribution). Community edition is fully functional.
- **S3 limitations**: No filesystem semantics (chmod, symlink) on S3
  backends — Kopia doesn't need them (flat blob storage).
- **Single point of failure**: SFTPGo replaces OpenSSH SFTP but is still
  a single daemon. Mitigated by systemd restart (bare-metal) or K8S
  liveness probe + restart policy (K8S).
- **K8S deployment + cluster down**: If SFTPGo runs in K8S and K3S is
  down, backup ingestion is unavailable. For critical backup paths
  (host-level Kopia), prefer the bare-metal deployment. K8S variant is
  for in-cluster consumers (Velero, CronJobs, app data export).
- **Public SFTP exposure** (Path B): Opens a port on bare-metal, deviating
  from ADR-008 zero-trust. Mitigated by 7 defense layers (see table
  above). Key residual risk: SFTPGo zero-day. Mitigated by: pinned
  binary version, CrowdSec rate limiting, UFW source IP restriction when
  clients have fixed IPs, and CryptFS ensuring data stays encrypted even
  if SFTPGo is compromised. Acceptable trade-off for clients that cannot
  use WireGuard.
