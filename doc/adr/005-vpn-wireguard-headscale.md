# ADR-005: VPN mesh — Two-tier design (WireGuard PTP + Headscale deferred)

**Status**: Done (revised 2026-05-24 — Tier 1 WireGuard PTP implemented, Headscale deferred)

**Context**: The repo uses native WireGuard for inter-node tunnels. The original
decision was to deploy Headscale (self-hosted Tailscale) as the primary mesh for
everything (infra + admin access). After analysis, Headscale is overkill for
infrastructure point-to-point links and introduces a K3S dependency on the
networking layer.

**Problem with Headscale-for-everything**:
- Headscale in K3S = SPOF. If K3S is down, new mesh connections fail.
- Maintaining two VPN stacks (Headscale + WG fallback) adds complexity.
- Infra services (Loki, backup, monitoring) need always-on connectivity that
  must not depend on a K3S pod being healthy.
- The old Elastic/Logstash setup used static WireGuard with authorized services
  and worked reliably for years.

**Decision**: Two-tier VPN architecture.

**Tier 1 — WireGuard PTP (per-plane isolation, always-on)**:
- Separated into 4 planes: `wg-admin` (ops), `wg-infra-ext` (relay↔ctrl services),
  `wg-relay-admin` (SSH to relay), `wg-infra-int` (inter-cluster mesh)
- Workers have NO WireGuard — intra-cluster networking uses Cilium (encrypted eBPF)
- Carries: mail relay, HTTPS (via wg-infra-ext), admin SSH/kubectl (via wg-admin),
  Garage replication (via wg-infra-int, future)
- Kernel-level, no K3S dependency, survives cluster outages
- Managed by existing `wireguard_server`/`wireguard_client`/`wireguard_meta` roles
- Static peer configs in Ansible Vault — no control plane needed
- Subnets: `10.99.98.0/24` (admin), `10.99.99.0/24` (infra-ext),
  `10.99.100.0/24` (infra-int) + ULA IPv6
- See `doc/networking.md#wireguard-plane-separation` for full topology

**Tier 2 — Headscale (future, scoped to human access)**:
- Admin laptop SSH, kubectl, Grafana dashboard access
- Could run as standalone systemd on a node (not in K3S) to avoid SPOF
- Not needed for infra-to-infra communication
- Lower priority; direct WG PTP client configs for admin access in the meantime
- Evaluate when the number of human clients justifies a control plane

**Relay tunnel topology — relay is the WG server** (decided 2026-05-27):

The cloud relay is the WG **server** (listens on a non-standard UDP port).
Self-hosted nodes are WG **clients** that initiate the connection.

Rationale:
- Self-hosted nodes are typically behind ISP NAT — no port-forwarding needed
  on the home router if the client initiates the connection.
- The relay already has a stable public IP — it's the natural listener.
- `persistent_keepalive: 25` keeps the tunnel alive through NAT/stateful
  firewalls without any ISP-side configuration.
- Moving/changing ISP: self-hosted reconnects automatically — no relay
  reconfiguration needed.
- Multi-cluster: each home cluster is a WG client peer on the relay server.
  Adding a cluster = adding a peer, no extra ports.

Alternative considered (relay=client, self-hosted=server): rejected because it
requires a port-forward on the home router/ISP, is fragile with dynamic IPs,
and complicates multi-cluster (each cluster needs a public port).

**Endpoint hardening**:

- **Port**: Use a non-standard port (not 51820). Eliminates opportunistic scanning.
  WG is crypto-stealth regardless of port, but non-standard avoids log noise.
  Configured via `wireguard_servers[].port` in inventory.
- **DNS**: Do NOT register the relay WG endpoint in public DNS. Raw IP or
  `/etc/hosts` only. Reasons:
  - No DNS dependency — tunnel works even if DNS is down or poisoned.
  - No public record advertising "VPN endpoint here" to attackers.
  - WG resolves endpoint once at startup — DNS adds no operational value.
- **Recommended pattern**: Use `/etc/hosts` on self-hosted nodes for readability
  without DNS exposure. The existing `hosts_entries` variable in the system role
  can manage this. Example:
  ```
  # /etc/hosts on self-hosted node (managed by Ansible)
  203.0.113.42  relay-infra
  ```
  Then in the WG client config: `endpoint: "relay-infra:<port>"`.
  If relay IP changes, Ansible updates `/etc/hosts` + restarts WG (handler).

Intra-cluster networking (ctrl↔worker) uses Cilium encrypted eBPF tunnels
(`nodeEncryption: true`). Workers have no WireGuard interfaces.

**Implementation**:
1. Per-plane WireGuard: each plane has dedicated interface, port, keys, and subnet
2. UFW: restrict SSH/K3S API to admin WG subnet (`10.99.98.0/24`) on bare-metal
3. Cloud relay: WG server on wg-infra-ext (ADR-006), ctrl connects as client
4. Admin access: `wg-admin` (blind DNAT via relay) or direct (fixed IP clusters)
5. Inter-cluster: `wg-infra-int` for Garage replication (future)
6. Headscale: defer to P-future, evaluate for admin/laptop access only
