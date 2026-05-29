# ADR-006: Mail architecture — cloud blind relay

**Status**: Done (revised 2026-05-27 — dual-stack HAProxy replaces DNAT)

**Context**: The mail server must run on bare-metal (local storage, full control)
but needs a stable public IP for DNS MX/PTR/SPF. The cloud free tier provides
a free IP but we don't want the cloud VPS to see the traffic.

**Decision**: Cloud relay node as a blind TCP relay via encrypted WireGuard tunnel.
HAProxy in TCP mode (layer 4) on the relay replaces raw DNAT, enabling:
- Dual-stack (IPv4 + IPv6) without NAT66 complexity
- PROXY protocol v2 to preserve real client IPs (IPv4 and IPv6)
- CrowdSec/fail2ban integration on the home cluster with original IPs
- Extensible to HTTPS/SNI routing (same HAProxy instance)

**Principle**:
- The relay node does NOT terminate TLS — TCP passthrough only
- TLS terminates on bare-metal (double encryption: TLS inside WireGuard)
- DKIM signing on bare-metal, private keys never on the relay node
- Mail storage 100% on bare-metal
- Client real IP preserved end-to-end via PROXY protocol v2

**Architecture**:
```
                    Internet (IPv4 + IPv6)
                           │
              ┌────────────┴────────────┐
              │     Cloud Relay Node     │
              │                          │
              │  HAProxy (TCP mode)      │
              │    bind *:25, [::]:25    │
              │    bind *:465, [::]:465  │
              │    bind *:993, [::]:993  │
              │    send-proxy-v2         │
              │                          │
              │  nftables (outbound)     │
              │    masquerade wg → eth0  │
              └────────────┬────────────┘
                           │ WireGuard tunnel (IPv4 internal)
                           │
              ┌────────────┴────────────┐
              │   Home K3S Cluster       │
              │                          │
              │  HAProxy Ingress         │
              │    reads PROXY protocol  │
              │    forwards to mailserver│
              │                          │
              │  Postfix/Dovecot         │
              │    sees real client IP   │
              │    TLS termination here  │
              │                          │
              │  CrowdSec                │
              │    bans on real IP       │
              └─────────────────────────┘
```

**Flows**:
```
Inbound:  Client (IPv4/IPv6) → relay HAProxy (TCP) → PROXY v2 → WG → K3S HAProxy → Postfix
Outbound: Postfix → WG → relay nftables masquerade → Internet (IPv4 only)
IMAP:     Client (IPv4/IPv6) → relay HAProxy (TCP) → PROXY v2 → WG → K3S HAProxy → Dovecot
```

**Why HAProxy replaces DNAT**:

| | DNAT (old) | HAProxy TCP (new) |
|---|---|---|
| IPv6 support | No (nftables can't DNAT IPv6→IPv4) | Yes (dual-stack bind) |
| Real IP preservation | Limited (conntrack) | PROXY protocol v2 (IPv4+IPv6) |
| Health checks | None | HAProxy checks backend |
| Logging | Kernel conntrack only | HAProxy access logs |
| CrowdSec bouncer | Needs nftables hooks | Native HAProxy integration |
| Rate limiting | Complex (nftables) | HAProxy stick-tables |
| Multiple services | One dest per port | Extensible (SNI routing on 443) |

**DNS required**:
```
mail.domain.com      A      → relay public IPv4
mail.domain.com      AAAA   → relay public IPv6
domain.com           MX 10  → mail.domain.com
domain.com           TXT    → "v=spf1 ip4:<RELAY_IPv4> ip6:<RELAY_IPv6> -all"
domain.com           TXT    → "v=DMARC1; p=reject; ..."
mail._domainkey      TXT    → (DKIM public key, generated on bare-metal)
<RELAY_IPv4> reverse PTR    → mail.domain.com
<RELAY_IPv6> reverse PTR    → mail.domain.com
```

**Relay HAProxy config** (TCP mode, no TLS termination):
```haproxy
global
    log stdout format raw local0

defaults
    mode tcp
    timeout connect 5s
    timeout client 300s
    timeout server 300s
    log global

frontend ft_smtp
    bind :25
    bind [::]:25 v6only
    default_backend bk_smtp

frontend ft_smtps
    bind :465
    bind [::]:465 v6only
    default_backend bk_smtps

frontend ft_imaps
    bind :993
    bind [::]:993 v6only
    default_backend bk_imaps

backend bk_smtp
    server k3s <wg_cluster_ip>:25 send-proxy-v2 check

backend bk_smtps
    server k3s <wg_cluster_ip>:465 send-proxy-v2 check

backend bk_imaps
    server k3s <wg_cluster_ip>:993 send-proxy-v2 check
```

**Outbound SMTP** (unchanged — nftables masquerade):
```
# Outbound traffic from WG tunnel exits via relay public IPv4
table ip nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "eth0" masquerade
    }
}
```

IPv6 outbound SMTP is not needed — deliverability depends on rDNS/SPF/DKIM,
not on the transport IP family. The relay exits in IPv4 with proper rDNS.

**WireGuard topology** (see ADR-005):

The relay is the WG **server** (public IP, listens on UDP 51820). Self-hosted
nodes are WG **clients** that initiate the connection with `persistent_keepalive`.
This avoids port-forwarding on home routers and works behind any ISP NAT.

**Resilience**:
- Relay node down: sending MXes retry ~5 days (standard SMTP behavior)
- Bare-metal down: same, mail queues at the sender
- WireGuard tunnel drops: auto-reconnect (persistent keepalive from client)
- HAProxy monitors backend health and logs connection failures

**Implementation**:
1. Role `cloud_relay`: HAProxy (Podman Quadlet, TCP mode) + masquerade in UFW
2. Role `wireguard_meta`: WG tunnel (relay = server, self-hosted = client)
3. HAProxy config templated from inventory (`relay_haproxy_frontends`)
4. Same HAProxy instance handles mail ports AND HTTPS/SNI (proposal-white-hole-extended)
5. K3S HAProxy Ingress sends PROXY protocol to mailserver (always on, ports 12525/10465/10587/10993)
6. K3S HAProxy Ingress accepts PROXY protocol from relay (conditional, `mail_relay_wg_ip` arg)
7. CrowdSec on home cluster sees real client IPs from PROXY protocol headers

**Kluctl configuration** (`mail_relay_wg_ip`):
- Empty (default): ingress receives direct connections, sees client IPs from TCP socket
- Set to relay WG IP (e.g. `10.99.99.1`): ingress accepts PROXY protocol from that source
  via `tcp-request connection expect-proxy layer4 if { src <ip> }`
- Mixed mode: connections from the relay carry PROXY headers, all others work normally

**PROXY protocol trust model — security rationale**:

The PROXY protocol header allows a proxy to inject the real client IP into the
connection metadata. If an untrusted source can send PROXY headers, it could
spoof any IP address. The `expect-proxy layer4 if { src <ip> }` directive
ensures only a single trusted source is allowed to inject these headers.

Why this is secure:

1. **WireGuard IP is non-routable** — the trusted IP (e.g. `10.99.99.1`) belongs
   to the WireGuard overlay network. It is not routable from the internet, the
   LAN, or the Kubernetes pod network. No external attacker can reach the ingress
   with this source IP.

2. **WireGuard is cryptographically authenticated** — each peer is identified by
   its Curve25519 public key. An attacker cannot spoof the relay's WG IP without
   possessing its private key. The tunnel provides mutual authentication, encryption,
   and replay protection.

3. **Pod network isolation** — even if a Kubernetes pod is compromised, it would
   connect from the pod CIDR (e.g. `10.42.0.0/16`), not from `10.99.99.1`. The
   `if { src }` ACL rejects PROXY headers from any source other than the relay.

4. **No PROXY header parsing for direct clients** — when a direct internet client
   connects (not via the relay), HAProxy does NOT expect a PROXY header. If a
   direct client sends a fake PROXY header, HAProxy treats it as application data
   (garbage to Postfix/Dovecot), causing the connection to fail — not an IP spoof.

5. **Defense in depth** — the mailserver's `proxyProtocol.trustedNetworks` (Dovecot's
   `haproxy_trusted_networks`) acts as a second layer. Even if a PROXY header somehow
   reaches Dovecot from an untrusted source, Dovecot only parses it from IPs in
   `trustedNetworks` (set to `pod_cidr` = the ingress pod IPs).

```
Threat: attacker sends forged PROXY header to spoof client IP

  Internet attacker → ingress:25
    → HAProxy does NOT expect PROXY (src != 10.99.99.1)
    → raw bytes forwarded to Postfix as application data
    → Postfix sees garbage, rejects → SAFE ✓

  Compromised pod → ingress:25
    → src = 10.42.x.x (pod CIDR), not 10.99.99.1
    → HAProxy does NOT expect PROXY from this source
    → SAFE ✓

  Legitimate relay → ingress:25
    → src = 10.99.99.1 (WG IP, authenticated by WG key)
    → HAProxy parses PROXY header, extracts real client IP
    → forwards with PROXY to mailserver → EXPECTED ✓
```

**Phase 1** (deploy without IPv6):
- HAProxy binds IPv4 only (remove `[::]:` lines)
- DNS A records only, no AAAA
- Add IPv6 later by adding `bind [::]:port v6only` + AAAA records + SPF update

**Related**: ADR-005 (VPN), ADR-008 (zero-trust), ADR-010 (multi-site),
proposal-white-hole-extended (HTTPS/SNI routing via same HAProxy)
