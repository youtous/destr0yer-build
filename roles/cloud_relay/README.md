# cloud_relay

HAProxy TCP relay + outbound masquerade for a cloud relay node (ADR-006, ADR-010).

This role handles only the relay-specific parts. WireGuard is configured
separately via the existing `wireguard_meta` / `wireguard_server` roles.

The relay is a blind forwarder — no TLS termination, no K3S.
HAProxy runs in a podman container via Quadlet.

## What it does

1. Validates required variables and IP forwarding (fail-fast assertions)
2. Deploys NAT masquerade rules into `/etc/ufw/before.rules` (outbound only)
3. Deploys HAProxy config (TCP mode, PROXY protocol v2, dual-stack ready)
4. Deploys HAProxy as a podman Quadlet container (read-only, network=host)

## Prerequisites

Applied before this role in the playbook:

- `iptables_firewall` — UFW + IP forwarding (creates `/etc/ufw/before.rules`)
- `wireguard_meta` — WireGuard interface up

## Playbook usage

```yaml
roles:
  - iptables_firewall      # UFW + sysctl ip_forward
  - wireguard_meta         # wg-infra interface + peers
  - cloud_relay            # HAProxy (Quadlet) + masquerade in UFW
  - monit_haproxy_relay    # monit checks on HAProxy ports + healthcheck
```

Target relay hosts only:

```sh
just configure --limit relay
just configure --limit relay --tags relay   # skip base config
```

## Architecture

```
Internet (IPv4 + IPv6)
       │
   HAProxy (podman Quadlet, TCP mode, network=host)
   ├── :25/:465/:993 → send-proxy-v2 → WG → K3S mail
   └── :443 (SNI) → send-proxy-v2 → WG → K3S web (optional)
       │
   UFW before.rules (outbound only)
   └── masquerade WG subnet → public interface (SMTP delivery)
```

- HAProxy does NOT terminate TLS (layer 4 passthrough)
- PROXY protocol v2 preserves real client IPs (IPv4 and IPv6)
- Backend (K3S HAProxy ingress / Postfix / Dovecot) reads PROXY protocol
- CrowdSec/fail2ban see real client IPs for threat detection
- IPv6 support: enabled via `relay_haproxy_ipv6: true`

## Security hardening

- **Container isolation**: podman Quadlet, `ReadOnly=true`, `NoNewPrivileges=true`
- **Minimal capabilities**: `DropCapability=ALL`, `AddCapability=NET_BIND_SERVICE`
- **Rate limiting**: stick-tables per source IP (configurable conn_rate/10s)
- **Connection limits**: max simultaneous connections per IP (default 200)
- **Healthcheck**: `haproxy -c -f ...` validates config integrity
- **Log rate limiting**: systemd `LogRateLimitBurst=1000/30s` prevents log saturation
- **No version disclosure**: no stats page exposed, logs to stdout (journald)

## WireGuard port filtering (PostUp iptables)

The WireGuard tunnel is locked down with dedicated iptables/ip6tables chains
that enforce least-privilege access in both directions:

**On the K3S node** (`wg-filter-relay` chain on INPUT):

- ACCEPT: ICMP/ICMPv6 (monitoring)
- ACCEPT: ESTABLISHED,RELATED (return traffic)
- ACCEPT: TCP ports 25, 465, 587, 993, 443, 80 (ingress-forwarded services)
- DROP: everything else (SSH, API server, kubelet, etcd blocked)

**On the relay** (`wg-filter-cluster` chain on INPUT):

- ACCEPT: ICMP/ICMPv6 (monitoring)
- ACCEPT: ESTABLISHED,RELATED (return traffic from relay's own connections)
- DROP: everything else (K3S cannot initiate connections to the relay)

Rules are applied as PostUp/PostDown in the WireGuard config, tied to the
tunnel lifecycle. Both IPv4 and IPv6 are filtered (prevents bypass via WG
IPv6 address). See `inventories/dev/host_vars/relay.sample.yml` for the
full example.

## Domain filtering

Traffic filtering works differently per protocol:

| Protocol | Layer | Filtering mechanism |
|----------|-------|---------------------|
| HTTPS (443) | TLS SNI | HAProxy extracts SNI from ClientHello; only domains listed in `relay_haproxy_sni_routes` are routed, unknown SNIs are rejected (`bk_sni_reject`) |
| SMTP (25) | Application | HAProxy cannot inspect SMTP envelope (layer 4 mode); domain filtering is handled by Postfix (`virtual_mailbox_domains`) — rejects mail for unconfigured domains |
| SMTPS/IMAPS (465/993) | Encrypted | Content invisible to relay (TLS passthrough); authentication enforced by Dovecot/Postfix |

The relay is intentionally a **layer 4 blind proxy** — it does not terminate
TLS and cannot inspect encrypted content. Domain-level access control is
enforced by the application layer (Postfix/Dovecot) which is the correct
place for it. This is the same model as cloud TCP load balancers (AWS NLB,
GCP TCP LB).

## Required variables

| Variable | Description | Example |
|---|---|---|
| `relay_haproxy_frontends` | TCP port→backend mappings | see below |
| `relay_public_interface` | Public-facing interface | `eth0` |
| `relay_wg_subnet` | WireGuard subnet for masquerade | `10.99.99.0/24` |

## Optional variables

| Variable | Default | Description |
|---|---|---|
| `relay_wg_interface` | `wg-infra` | WG interface name |
| `relay_haproxy_ipv6` | `false` | Bind IPv6 on all frontends |
| `relay_haproxy_image` | `docker.io/haproxytech/haproxy-alpine:3.3` | Container image (renovate-managed) |
| `relay_haproxy_sni_routes` | `[]` | HTTPS SNI routing table (see below) |
| `relay_haproxy_sni_port` | `443` | SNI frontend listen port |
| `relay_haproxy_http_redirect` | `true` | Enable port 80 → HTTPS redirect |
| `relay_haproxy_timeout_connect` | `5s` | HAProxy connect timeout |
| `relay_haproxy_timeout_client` | `300s` | Client timeout (IMAP IDLE needs long) |
| `relay_haproxy_timeout_server` | `300s` | Server timeout |
| `relay_haproxy_max_conn_per_ip` | `200` | Max simultaneous connections per source IP |
| `relay_haproxy_conn_rate_limit` | `120` | Max new connections per 10s per source IP |
| `relay_haproxy_log_level` | `info` | HAProxy log level (filters debug noise) |

WireGuard variables (`wireguard_servers`, peers, keys) are handled by
`wireguard_meta` / `wireguard_server` — see their docs.

## HAProxy frontends format

No defaults — must be defined in inventory:

```yaml
relay_haproxy_frontends:
  - name: smtp
    bind_port: 25
    backend_addr: "10.99.99.10:25"
  - name: smtps
    bind_port: 465
    backend_addr: "10.99.99.10:465"
  - name: imaps
    bind_port: 993
    backend_addr: "10.99.99.10:993"
```

## SNI routing (HTTPS)

Uses `tcp-request inspect-delay 5s` to extract the TLS ClientHello SNI and
route to the appropriate backend. This is TLS passthrough — HAProxy never
decrypts the traffic.

```yaml
relay_haproxy_sni_port: 443  # default; override if 443 is taken (e.g. dev)
relay_haproxy_sni_routes:
  - sni: grafana.example.com
    backend_addr: "10.99.99.10:443"
  - sni: auth.example.com
    backend_addr: "10.99.99.10:443"
  - sni: legacy.example.com
    backend_addr: "10.99.99.10:443"
    send_proxy: false  # backend does not support PROXY protocol
```

Unknown SNIs are dropped (empty `bk_sni_reject` backend, 5s timeout).

### `send_proxy` option (per route)

| Value | Behavior |
|-------|----------|
| `true` (default) | HAProxy sends PROXY protocol v2 header — backend sees real client IP |
| `false` | Plain TCP forwarding — backend sees relay IP |

**Recommendation: always use `send_proxy: true`** (the default) unless the
backend does not support PROXY protocol. Knowing the real client IP is critical
for:

- **Security**: CrowdSec/fail2ban threat detection based on source IP
- **Compliance**: accurate access logs in Loki/Grafana
- **Rate limiting**: backend can rate-limit per real client, not per relay
- **Anti-abuse**: SPF validation, geo-blocking, DMARC alignment

The only reason to disable it is when the backend cannot parse PROXY protocol
(legacy service, third-party SaaS endpoint). In that case the backend sees
the relay's WireGuard IP as the client — acceptable when client IP identity
is irrelevant.

### HTTP→HTTPS redirect (port 80)

When SNI routes are configured, an `ft_http_redirect` frontend on port 80
sends a `301 → https://` redirect. Disable with:

```yaml
relay_haproxy_http_redirect: false  # skip port 80 bind (e.g. port conflict in dev)
```

## UFW port opening

The relay's firewall (UFW) denies incoming by default. HAProxy ports must be
opened via `ufw_additional_rules` in the relay's host_vars:

```yaml
ufw_additional_rules:
  - { comment: "SMTP", proto: tcp, src: any, dest: any, port: "25", rule: allow, direction: in }
  - { comment: "SMTPS", proto: tcp, src: any, dest: any, port: "465", rule: allow, direction: in }
  - { comment: "IMAPS", proto: tcp, src: any, dest: any, port: "993", rule: allow, direction: in }
```

The WG port is opened by `wireguard_server` role's firewall tasks (via `restrict_ips`).

## Deployment phases

**Phase 1** (IPv4 only): `relay_haproxy_ipv6: false`
- Only A records in DNS, no AAAA
- Validates full chain works before adding complexity

**Phase 2** (dual-stack): `relay_haproxy_ipv6: true`
- Add AAAA records for mail.domain.com
- Update SPF with `ip6:<relay_ipv6>`
- Add PTR for IPv6

## WireGuard topology

The relay is the WG **server** (public IP, non-standard port). Self-hosted
nodes are WG **clients** (behind NAT, initiate connection). See ADR-005.

Endpoint hardening:
- Use a non-standard WG port (not 51820)
- Do NOT register WG endpoint in public DNS — use raw IP or `/etc/hosts`
- See `inventories/dev/host_vars/relay.sample.yml` for full example
