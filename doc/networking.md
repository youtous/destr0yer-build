# Networking

Decisions: [ADR-005](adr/005-vpn-wireguard-headscale.md) (WireGuard VPN),
[ADR-011](adr/011-ingress-gateway-haproxy.md) (HAProxy Ingress)

## Overview

Two layers: host-level WireGuard mesh (always-on, K3S-independent) and K8S-level
HAProxy Ingress (DaemonSet on hostNetwork). The cloud relay extends the mesh to
the public internet via nftables DNAT.

```
ctrl.k3s.dev.local
  ├── eth0: 192.168.56.10 (LAN)
  ├── wg0:  10.99.99.1/24  [WG server, UDP 1990]
  └── HAProxy DaemonSet (hostNetwork :80/:443/:25/:465/:993)

worker.k3s.dev.local
  ├── eth0: 192.168.56.11 (LAN)
  ├── wg0:  10.99.99.2/24  [WG client → ctrl:1990, split tunnel]
  └── HAProxy DaemonSet (hostNetwork)

relay.example.com (prod edge)
  ├── eth0: public IP
  ├── wg-infra: → cluster WG IP  [UDP 51820]
  └── nftables DNAT (mail ports only)
```

## WireGuard VPN

**Roles**: `roles/wireguard_server/`, `roles/wireguard_client/`,
`roles/wireguard_meta/` (orchestrator).

Deployed by `playbooks/01-configure.yml` on the `wireguard_peers` group.
`wireguard_meta` loops over `wireguard_servers[]` and `wireguard_clients[]`
lists, calling the appropriate role for each interface. Asserts no duplicate
interface names.

**Server** (ctrl): listens on UDP 1990, addresses `10.99.99.1/24` +
`fdc9:281f:04d7:9ee9::1/64`. PostUp enables IP forwarding + MASQUERADE on the
external interface.

**Client** (worker): connects to ctrl:1990, split-tunnel (`10.99.99.0/24` only
in dev), persistent keepalive 25s for NAT traversal.

**Cloud relay**: separate interface `wg-infra` (port 51820). HAProxy in TCP mode
(dual-stack IPv4+IPv6) forwards mail (25/465/993) and HTTPS (443 via SNI routing)
to the cluster over WG. All frontends use PROXY protocol v2 to preserve real
client IPs (including IPv6). Outbound SMTP uses nftables masquerade (IPv4 only).
See ADR-006 (revised) and proposal-white-hole-extended for details.

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
`10.99.99.0/24` (WG), `10.42.0.0/16` (pods), `10.43.0.0/16` (services),
`192.168.56.0/24` (dev LAN).

## Cilium Gateway API

Scaffolded in `kluctl/security/gateway/` with a `Gateway` resource and a test
`HTTPRoute` for whoami. Currently deferred — HAProxy handles all production
traffic. Cilium Gateway is available for experimentation.

## Operations

```sh
just deploy-only ingress/haproxy  # redeploy HAProxy
just configure                    # redeploy WireGuard (all host roles)
```
