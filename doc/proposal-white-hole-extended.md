# Proposal: White Hole Extended — Exposing Home Cluster Services via Relay

Status: Implemented (2026-05-27)
Related: ADR-005 (VPN), ADR-006 (mail relay), ADR-008 (zero-trust), ADR-010 (multi-site)

---

## Problem

Home clusters host services (websites, dashboards, APIs) that need to be
reachable from the public internet. Today the relay pattern only covers mail
(ADR-006). Extending it to web/HTTP requires solving:

1. **Multiple services on ports 80/443** — mail uses unique ports, but web services
   all share 80/443. The relay must route to the correct home cluster.
2. **Home cluster IP never exposed** — the public IP is always the relay's.
3. **No public DNS management from home clusters** — home clusters should not need
   to update DNS records. The relay owns the public IP; DNS points there.
4. **Internal access without the relay** — admins on VPN should reach services
   directly via private IPs, bypassing the relay entirely.

---

## Proposed Architecture

```
                        Public Internet
                              │
                              │ DNS: *.example.com → relay public IP
                              │
                         ┌────┴────┐
                         │  Relay  │  SNI-based TCP proxy (no TLS termination)
                         │  Node   │  port 80: HTTP→HTTPS redirect only
                         └────┬────┘
                              │
                     WireGuard PTP mesh (10.99.99.0/24)
                              │
              ┌───────────────┼───────────────┐
              │               │               │
       ┌──────┴──────┐ ┌─────┴──────┐ ┌──────┴──────┐
       │ Home-1 K3S  │ │ Home-2 K3S │ │ Backup node │
       │ (zone A)    │ │ (zone B)   │ │             │
       │             │ │            │ │             │
       │ grafana     │ │ home-      │ │ garage      │
       │ authelia    │ │ assistant  │ │ replica     │
       │ mail        │ │ site-b    │ │             │
       └─────────────┘ └────────────┘ └─────────────┘
              ▲               ▲
              │  Headscale    │
              │  (admin VPN)  │
              │               │
       ┌──────┴───────────────┘
       │ Admin device
       │ (laptop / phone)
       │
       │ DNS: *.internal.example.com → WG IPs (public DNS, private values)
       │  OR: Headscale MagicDNS → nodename.ts.net
       └──────────────────────────────
```

---

## Component 1: SNI-Based TCP Proxy on Relay

The relay inspects the TLS ClientHello SNI field and routes to the correct
home cluster over WireGuard. **No TLS termination** — the relay stays blind,
consistent with ADR-006 and ADR-008.

### How it works

1. Client connects to `grafana.example.com:443`
2. DNS resolves to relay public IP
3. Relay HAProxy reads SNI from ClientHello (TCP mode, no decryption)
4. Routes to `10.99.99.1:443` (home-1) or `10.99.99.3:443` (home-2) based on SNI map
5. Home cluster Cilium Gateway / HAProxy handles TLS termination + routing

### HAProxy configuration sketch (relay, TCP mode)

```
frontend https_sni
    bind *:443
    bind [::]:443 v6only
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }

    # Route by SNI to home clusters
    use_backend home1 if { req_ssl_sni -i grafana.example.com }
    use_backend home1 if { req_ssl_sni -i auth.example.com }
    use_backend home1 if { req_ssl_sni -i mail.example.com }
    use_backend home2 if { req_ssl_sni -i ha.example.com }
    use_backend home2 if { req_ssl_sni -i site-b.example.com }

    # Fallback: reject unknown SNI
    default_backend reject

frontend http_redirect
    bind *:80
    bind [::]:80 v6only
    mode http
    http-request redirect scheme https code 301

backend home1
    mode tcp
    server ctrl 10.99.99.1:443 send-proxy-v2 check

backend home2
    mode tcp
    server home2 10.99.99.3:443 send-proxy-v2 check

backend reject
    mode tcp
    no option
```

### Ansible implementation

- New role: `relay_sni_proxy` (HAProxy in TCP/SNI mode on relay node)
- SNI routing table defined in inventory (per home cluster):
  ```yaml
  relay_sni_routes:
    - sni: grafana.example.com
      backend: 10.99.99.1:443
    - sni: auth.example.com
      backend: 10.99.99.1:443
    - sni: ha.example.com
      backend: 10.99.99.3:443
  ```
- Home clusters never touch DNS — relay owner manages `*.example.com` records
- Adding a new service = add SNI entry in relay inventory + deploy

### Advantages over DNAT

| | DNAT (current mail pattern) | SNI proxy (proposed) |
|---|---|---|
| Multiple services on 443 | No — one destination per port | Yes — routes by hostname |
| Relay stays blind | Yes | Yes (TCP mode, no decryption) |
| Health checks | No | Yes (HAProxy checks backend) |
| Logging | Minimal (kernel DNAT) | Full access logs (HAProxy) |
| CrowdSec integration | Needs iptables hooks | Native HAProxy bouncer |
| Failover | None | HAProxy can mark backends down |

### What about plain HTTP (port 80)?

Port 80 on the relay does a simple HTTP→HTTPS redirect. No SNI inspection
needed — all real traffic goes to 443. This is a single `http-request redirect`
rule, not a proxy.

### Mail ports — same HAProxy instance (revised 2026-05-27)

SMTP/IMAP ports (25, 465, 993) use the **same HAProxy** in TCP mode with
PROXY protocol v2 (see revised ADR-006). The relay runs a single HAProxy
handling both mail (TCP passthrough + PROXY v2) and web (SNI routing + PROXY v2).
This replaces the original DNAT approach, enabling dual-stack IPv6 and real IP
preservation for CrowdSec/fail2ban on the home cluster.

All frontends bind dual-stack (`*:port` + `[::]:port v6only`) for IPv6 readiness.

---

## Component 2: DNS Strategy

### Public DNS (managed centrally, not by home clusters)

```
# All point to the relay public IP — home clusters never update these
grafana.example.com     A     <relay-public-ip>
auth.example.com        A     <relay-public-ip>
ha.example.com          A     <relay-public-ip>
mail.example.com        A     <relay-public-ip>
example.com             MX    mail.example.com
```

Home clusters **never** need to update public DNS. The relay owns the public IP
and all public DNS records. Adding a service = add an SNI route on the relay +
add a DNS A record pointing to the relay.

### Private DNS for VPN access (three options analyzed)

#### Option A: Private IPs in public DNS

```
# Same public DNS zone, private values — only reachable via VPN
internal.example.com          A     10.99.99.1
grafana.internal.example.com  A     10.99.99.1
ha.internal.example.com       A     10.99.99.3
```

- Private IPs in public DNS is a valid pattern (RFC 1918 + split access).
  Google does this (`restricted.googleapis.com` → private IPs).
- The IPs are useless without VPN — no meaningful information leak.
- **No DNS server to maintain** — works with any public DNS provider.

**Downsides:**
- Manual: adding a service = adding a DNS record.
- Two hostnames per service (public + internal).
- Pollutes public DNS zone with private addresses.

**Verdict: fallback option only.** Works but not ideal.

#### Option B: Headscale MagicDNS (node-level)

```
# Automatic, no manual DNS management
ctrl.ts.net           → 100.64.0.1  (Headscale CGNAT range)
home2.ts.net          → 100.64.0.2
```

- Fully automatic hostname resolution for Headscale clients.
- No public DNS involved at all — MagicDNS resolves locally on each client
  via the `100.100.100.100` virtual resolver. No records are created in any
  public DNS zone.
- Only works for Headscale clients (not pure WireGuard peers).
- Hostnames are **node-level**, not service-level (`ctrl.ts.net` not
  `grafana.ts.net`). Needs port or reverse proxy on the node.

**Verdict: good for SSH/admin, not for service-level DNS.**

#### Option C: Headscale Split DNS + CoreDNS (recommended)

The key Tailscale/Headscale feature for this use case is **Split DNS**:
Headscale delegates an entire domain (e.g. `k8s.home`) to a DNS server
inside the tailnet (CoreDNS running in the K3S cluster).

```yaml
# headscale config.yaml
dns:
  magic_dns: true
  base_domain: ts.example.com
  nameservers:
    global:
      - 1.1.1.1
    split:
      # All *.k8s.home queries → CoreDNS on ctrl via Headscale tunnel
      k8s.home:
        - 100.64.0.1    # ctrl node's Headscale IP
```

**How it works:**

1. Admin on Headscale types `grafana.k8s.home` in browser
2. OS DNS query intercepted by Tailscale client resolver (`100.100.100.100`)
3. Headscale sees `k8s.home` matches split DNS rule
4. Query forwarded to CoreDNS on ctrl **through the WireGuard tunnel**
5. CoreDNS resolves `grafana.k8s.home` → Ingress/Gateway IP of the cluster
6. Traffic flows directly over tailnet — relay never involved

**Why this is the best approach:**

- **Zero public DNS involvement** — no records created, no zone pollution.
  MagicDNS + split DNS are entirely private to the tailnet.
- **Automatic service discovery** — CoreDNS in K3S already knows every
  Ingress hostname. Adding a new service with an Ingress rule = instantly
  resolvable for all Headscale clients. Zero manual DNS management.
- **Single source of truth** — CoreDNS is the authority for `*.k8s.home`,
  same as in-cluster resolution. No record duplication.
- **Same URL everywhere** — `grafana.k8s.home` works both inside the cluster
  (pod DNS) and from admin devices (via split DNS). No `internal.*` prefix.
- **Per-cluster isolation** — each home cluster runs its own CoreDNS. Split
  DNS delegates `k8s-a.home` → cluster A, `k8s-b.home` → cluster B.

**Known caveat:** Headscale issue [#1206](https://github.com/juanfont/headscale/issues/1206)
— `extra_records` don't work well with split DNS on clients that handle split
DNS natively (systemd-resolved). This does NOT affect the split DNS delegation
approach (which uses `restricted_nameservers` / `split`, not `extra_records`).

**CoreDNS prerequisite:** CoreDNS must be configured to resolve Ingress
hostnames to the cluster Ingress IP. By default K3S CoreDNS only resolves
`*.svc.cluster.local`. A small Corefile addition is needed:

```
k8s.home:53 {
    hosts {
        <ingress-ip>  grafana.k8s.home
        <ingress-ip>  auth.k8s.home
        fallthrough
    }
    forward . /etc/resolv.conf
}
```

Or better: use the [k8s_gateway](https://github.com/ori-edge/k8s_gateway)
CoreDNS plugin which auto-discovers Ingress/Gateway hostnames — zero manual
host entries.

### Recommendation: Option C (Split DNS) + Option B (MagicDNS) combined

- **Option C** (Split DNS → CoreDNS) for **service-level access**:
  `grafana.k8s.home`, `auth.k8s.home` — automatic discovery, same URL as
  in-cluster, zero public DNS management.
- **Option B** (MagicDNS) for **node-level access**: `ctrl.ts.net`,
  `worker.ts.net` — SSH, kubectl, k9s.
- **Option A** (private IPs in public DNS) as **fallback only** — for
  non-Headscale clients that need stable FQDNs (CI/CD runners, Ansible,
  monitoring from outside the tailnet). Keep this minimal.
- All three coexist without conflict. Split DNS is the primary mechanism;
  MagicDNS is automatic; public DNS fallback is opt-in per service.

---

## Component 3: Headscale vs Pure WireGuard for Internal Access

### Use case separation

| Use case | WireGuard PTP | Headscale |
|----------|--------------|-----------|
| **Infra mesh** (node↔node, always-on) | **Keep** | Overkill |
| **Admin access** (laptop/phone → cluster) | Painful | **Use this** |
| **CI/CD access** (GitHub Actions → cluster) | OK (static key) | OK |
| **Guest/temporary access** | Impossible | Easy (pre-auth keys + expiry) |
| **Per-user ACLs** | No | Yes |
| **Device onboarding** | Re-deploy Ansible | QR code / auth key |
| **NAT traversal** | Manual keepalive | Built-in DERP relay |
| **MagicDNS** | No | Yes |

### Recommendation: Headscale for admin/user access (Tier 2)

This aligns exactly with the deferred Tier 2 from ADR-005. The concrete use
case is now clear:

**Headscale handles:**
- Admin laptops/phones accessing internal services
- Per-user ACLs (admin sees everything, monitoring-only user sees Grafana)
- Dynamic device registration (no Ansible re-deploy per device)
- MagicDNS for convenience (`ctrl.ts.net`)
- DERP relay for NAT traversal (admin behind hotel WiFi)
- Pre-auth keys with expiry for temporary access

**WireGuard PTP continues to handle:**
- Node-to-node infra mesh (Alloy→Loki, Kopia SFTP, K3S API, Garage)
- Relay-to-home-cluster forwarding (SNI proxy backends)
- Anything that must survive K3S/Headscale outage

### Headscale deployment location

**Option**: Run Headscale on the relay node as a systemd service (not in K3S).

- Relay already has a public IP and is reachable from the internet.
- Headscale registration endpoint needs to be reachable for new device onboarding.
- Running outside K3S avoids the SPOF concern from ADR-005.
- Existing WireGuard mesh connections are unaffected if Headscale goes down
  (only new registrations fail).
- Lightweight: Headscale is a single Go binary (~30 MB RAM).

```
Relay node (systemd):
  ├── WireGuard PTP          (infra mesh, always-on)
  ├── Headscale              (admin VPN control plane)
  ├── HAProxy SNI proxy      (web traffic forwarding)
  ├── DNAT rules             (mail forwarding)
  ├── Gatus                  (uptime checks)
  ├── Alloy                  (log shipping)
  ├── node-exporter          (metrics)
  └── fail2ban               (abuse protection)
```

### Headscale ACL sketch

```json
{
  "acls": [
    {
      "action": "accept",
      "src": ["group:admin"],
      "dst": ["*:*"]
    },
    {
      "action": "accept",
      "src": ["group:monitoring"],
      "dst": [
        "ctrl:3000",
        "ctrl:9090"
      ]
    }
  ],
  "groups": {
    "group:admin": ["user1@example.com"],
    "group:monitoring": ["oncall@example.com"]
  }
}
```

---

## Traffic Flow Summary

### External user accessing `grafana.example.com`

```
Browser → DNS (grafana.example.com → relay IP)
       → relay:443 (HAProxy reads SNI)
       → WireGuard tunnel to 10.99.99.1:443
       → Home-1 Cilium Gateway / HAProxy
       → Grafana pod (TLS terminated here)
```

Relay is blind. Home cluster IP never exposed. No DNS update needed from home.

### Admin on Headscale accessing `grafana.k8s.home` (Split DNS)

```
Browser → OS resolver (100.100.100.100)
       → Headscale split DNS: k8s.home → CoreDNS on ctrl (via tunnel)
       → CoreDNS resolves grafana.k8s.home → cluster Ingress IP
       → Headscale tunnel directly to ctrl:443
       → Cilium Gateway / HAProxy → Grafana pod
```

Direct path, bypasses relay entirely. Faster, lower latency. Same URL as
in-cluster. No public DNS touched — resolution is entirely within the tailnet.

### Admin on Headscale accessing `ctrl.ts.net` (MagicDNS)

```
Browser → Headscale MagicDNS (ctrl.ts.net → 100.64.0.1)
       → Headscale tunnel to ctrl
       → SSH / kubectl / k9s
```

Automatic node-level resolution. No DNS configuration needed at all.

---

## Implementation Plan (if accepted)

| Phase | Task | Effort | Depends on |
|-------|------|--------|------------|
| 1 | SNI proxy role for relay (`relay_sni_proxy`) | Medium | Relay node provisioned |
| 1 | SNI routing table in inventory | Low | — |
| 1 | Public DNS records (A records → relay IP) | Low | DNS provider access |
| 2 | Headscale systemd role for relay | Medium | Relay node provisioned |
| 2 | Headscale ACL configuration | Low | Headscale running |
| 2 | Headscale split DNS config (`k8s.home` → CoreDNS) | Low | Headscale + CoreDNS |
| 2 | CoreDNS Corefile: k8s_gateway plugin or hosts block | Low | K3S running |
| 3 | CrowdSec bouncer on relay HAProxy | Low | SNI proxy + CrowdSec |
| 3 | Health check integration (Gatus → SNI backends) | Low | SNI proxy running |
| 3 | Documentation + ADR update | Low | — |

### Blockers

- Relay node must be provisioned first (ADR-010 / CLAUDE.md task #9)
- Home cluster ingress (Cilium Gateway or HAProxy) must be working to receive
  forwarded traffic
- cert-manager on home clusters must issue certs for the public hostnames
  (DNS-01 via deSEC, since the home cluster doesn't own port 80 — the relay does)

### cert-manager consideration

Home clusters use DNS-01 challenges (not HTTP-01) because the relay owns
ports 80/443. The home cluster requests a cert for `grafana.example.com`,
proves ownership via deSEC DNS TXT record, and cert-manager issues the cert.
This is already supported by the existing cert-manager + desec-webhook setup.

---

## Decision Points (for discussion)

1. **SNI proxy vs reverse proxy**: SNI proxy keeps relay blind (recommended).
   Reverse proxy allows relay-level WAF/rate-limiting but breaks zero-trust.
   Middle ground: CrowdSec bouncer on HAProxy TCP mode (rate-limit by IP
   without decrypting).

2. **Internal DNS strategy**: Split DNS via Headscale (delegate `k8s.home` to
   CoreDNS) is the primary mechanism — zero public DNS involvement, automatic
   service discovery. MagicDNS for node-level access. Private IPs in public
   DNS only as fallback for non-Headscale clients (CI/CD, Ansible).

3. **Headscale on relay vs standalone VM**: Relay is simplest (already public,
   already provisioned). Standalone VM adds isolation but more infra to manage.
   Recommendation: relay node (systemd service).

4. **One relay or multiple**: Single relay is a SPOF for public access. For
   HA: two relays with DNS failover (low TTL). Defer to when needed.

5. **PROXY protocol**: ~~If home clusters need the real client IP~~ — **Decided**:
   PROXY protocol v2 is enabled on ALL relay frontends (mail + HTTPS). The home
   cluster HAProxy reads it and forwards the real client IP (IPv4 or IPv6) to
   backends. This is required for CrowdSec, fail2ban, and Authelia IP-based rules.
   See revised ADR-006 for the complete pattern.
