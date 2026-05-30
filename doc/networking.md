# Networking

Decisions: [ADR-005](adr/005-vpn-wireguard-headscale.md) (WireGuard VPN),
[ADR-011](adr/011-ingress-gateway-haproxy.md) (HAProxy Ingress)

## Overview

Two layers: host-level WireGuard planes (always-on, K3S-independent) and
K8S-level HAProxy Ingress (DaemonSet on hostNetwork). The cloud relay extends
the mesh to the public internet via HAProxy TCP + DNAT. Intra-cluster pod
networking is handled by Cilium (encrypted eBPF tunnels), not WireGuard.

### WireGuard plane separation

Each WireGuard plane has its own keys, port, and trust boundary. Compromising
one plane does not expose the others. See [security.md](security.md#wireguard-plane-isolation)
for the threat model.

| Plane | Port | Purpose | Who terminates |
|-------|------|---------|----------------|
| `wg-relay-admin` | 41995 | Admin SSH to relay | Relay (decrypts) |
| `wg-admin` | 41994 | Admin ops (SSH, kubectl) to clusters | Each cluster ctrl (decrypts). Relay = blind DNAT. |
| `wg-infra-ext` | 41993 | Public services (relay → ctrl via HAProxy TCP) | Relay + ctrl (both decrypt) |
| `wg-infra-int` | 41991 | Inter-cluster mesh (Garage replication, future) | Each cluster ctrl (both decrypt) |

Design principle: the relay is the most exposed node (public IP, open ports).
It holds the minimum number of WG keys — only `wg-relay-admin` and `wg-infra-ext`.
Admin traffic passes through as opaque UDP (DNAT), never decrypted.

### Network topology

```
                               ┌─────────────────────────┐
  wg-relay-admin :41995       │                         │
  ┌──────────────────────────►│        RELAY            │
  │  (SSH to relay only)      │   relay.example.com     │
  │                           │                         │
  │  wg-admin :41994          │  wg-relay-admin :41995  │
  │  ┌───────────────────────►│  wg-infra-ext   :41993  │
  │  │  (relay = blind DNAT)  │  DNAT :41994 ──────┐    │
  │  │                        └────────────┬───────┼────┘
  │  │                                     │       │
  │  │                          wg-infra-ext       │ DNAT via
  │  │                          (HAProxy TCP:      │ wg-infra-ext
  │  │                           mail, HTTPS)      │
┌─┴──┴──────────┐                          │       │
│               │               ┌──────────┴───────┴───┐
│   Admin PC    │               │       CTRL           │
│               │               │  ctrl.k3s.dev.local  │
│               │               │                      │
│               │               │  wg-admin     :41994 │
│               │               │  wg-infra-ext :41993 │
│               │               │  wg-infra-int :41991 │
└───┬───────────┘               └──────────┬───────────┘
    │                                      │
    │                           wg-infra-int (inter-cluster)
    │                                      │
    │  wg-admin :41994          ┌──────────┴───────────┐
    │  (direct, DC2 has         │       DC2            │
    │   fixed IP)               │  dc2.example.com     │
    └──────────────────────────►│                      │
                                │  wg-admin     :41994 │
                                │  wg-infra-int :41991 │
                                └──────────────────────┘
```

### WireGuard interfaces per node

| Node | Interface | Port | Subnet | Peers |
|------|-----------|------|--------|-------|
| **Ctrl** | `wg-admin` | 41994 | `10.99.98.0/24` | admin (via relay DNAT) |
| | `wg-infra-ext` | 41993 | `10.99.99.0/24` | relay |
| | `wg-infra-int` | 41991 | `10.99.100.0/24` | DC2 (future) |
| **Relay** | `wg-relay-admin` | 41995 | `10.99.98.0/24` | admin |
| | `wg-infra-ext` | 41993 | `10.99.99.0/24` | ctrl |
| | — (DNAT rule) | 41994 | — | blind forward → ctrl:41994 |
| **DC2** | `wg-admin` | 41994 | `10.99.98.0/24` | admin (direct) |
| | `wg-infra-int` | 41991 | `10.99.100.0/24` | ctrl |

Worker nodes have no WireGuard interfaces — intra-cluster networking is
handled by Cilium (encrypted eBPF tunnels, `nodeEncryption: true`).

### Node details (dev)

```
ctrl.k3s.dev.local
  ├── eth0:          192.168.56.10 (LAN)
  ├── wg-admin:      10.99.98.1/24   [UDP 41994, admin access]
  ├── wg-infra-ext:  10.99.99.1/24   [UDP 41993, relay services]
  └── HAProxy DaemonSet (hostNetwork :80/:443/:25/:465/:993)

worker.k3s.dev.local
  ├── eth0:          192.168.56.11 (LAN)
  └── HAProxy DaemonSet (hostNetwork)

relay.example.com (prod edge)
  ├── eth0:          public IP
  ├── wg-infra-ext:  10.99.99.x/24   [UDP 41993, → ctrl]
  ├── wg-relay-admin:10.99.98.x/24   [UDP 41995, admin SSH]
  └── iptables DNAT: eth0:41994 → ctrl:41994 (blind UDP pipe)
```

## WireGuard VPN

**Roles**: `roles/wireguard_server/`, `roles/wireguard_client/`,
`roles/wireguard_meta/` (orchestrator).

Deployed by `playbooks/01-configure.yml` on the `wireguard_peers` group.
`wireguard_meta` loops over `wireguard_servers[]` and `wireguard_clients[]`
lists, calling the appropriate role for each interface. Asserts no duplicate
interface names.

**Admin plane** (`wg-admin`): each cluster ctrl listens on UDP 41994. For
clusters behind a relay (no fixed IP), the relay blindly DNATs UDP from
`eth0:41994` to `ctrl:41994` — same port both sides, no port translation.
For clusters with a fixed IP, admin connects directly. Separate WG keys per
cluster. See [security.md](security.md#wireguard-plane-isolation) for the
trust model.

**External infra** (`wg-infra-ext`): relay ↔ ctrl on port 41993. HAProxy in
TCP mode (dual-stack IPv4+IPv6) forwards mail (25/465/993) and HTTPS (443 via
SNI routing) to the cluster over this tunnel. PROXY protocol v2 preserves real
client IPs. Outbound SMTP uses masquerade (IPv4 only).

**Internal infra** (`wg-infra-int`): ctrl ↔ DC2 on port 41991. Used for
inter-cluster traffic (Garage S3 replication, future cross-site services).
Not yet deployed — see next steps in [AGENTS.md](../AGENTS.md#next-steps-priority-order).

**Relay admin** (`wg-relay-admin`): admin ↔ relay on port 41995. Only allows
SSH to the relay itself (iptables restricts to tcp/22). Separate keys from
`wg-admin` — a compromised relay admin key cannot access any cluster.

**Monit**: `roles/monit_wireguard/` watches each WG interface.

## HAProxy Ingress

**Kluctl Helm**: `kluctl/ingress/haproxy/`, chart `haproxy-ingress` v0.16.1.

**Key design choices**:
- **DaemonSet** with `hostNetwork: true` — binds directly to host ports 80/443
- Default `IngressClass` (Traefik disabled in K3S config)
- Gateway API watching disabled (`watch-gateway: false`)

**UFW and hostNetwork**: Because HAProxy listens on the node's network stack,
pod-to-node traffic traverses the host firewall (UFW) — unlike pod-to-ClusterIP
traffic which stays in Cilium eBPF. The `ufw_additional_rules` in the inventory
must allow `local_container_ips` (pod CIDR) on all HAProxy ports (80, 443, 25,
465, 587, 993). Without this, in-cluster health checks (Gatus), OIDC callbacks
(Grafana → Authelia via Ingress), and MX loopback will timeout.

**HTTP/HTTPS**:
- Global source allowlist from `args.trusted_cidrs` (WG subnet, pod CIDRs, dev LAN)
- Per-Ingress override via `haproxy-ingress.github.io/allowlist-source-range`
- HSTS, security headers, SSL redirect enabled

**TCP passthrough** (mail):

| Host port | Backend | Protocol |
|-----------|---------|----------|
| 25 | `mail/mailserver:12525` | PROXY protocol |
| 465 | `mail/mailserver:10465` | PROXY protocol |
| 993 | `mail/mailserver:10993` | PROXY protocol |

**Trusted CIDRs** (synced between Ansible and Kluctl): `127.0.0.0/8`, `::1/128`,
`10.99.98.0/24` (wg-admin/relay-admin), `10.99.99.0/24` (wg-infra-ext),
`10.42.0.0/16` (pods), `10.43.0.0/16` (services), `192.168.56.0/24` (dev LAN).

## Cilium Gateway API

Scaffolded in `kluctl/security/gateway/` with a `Gateway` resource and a test
`HTTPRoute` for whoami. Currently deferred — HAProxy handles all production
traffic. Cilium Gateway is available for experimentation.

## Operations

```sh
just deploy-only ingress/haproxy  # redeploy HAProxy
just configure                    # redeploy WireGuard (all host roles)
```
