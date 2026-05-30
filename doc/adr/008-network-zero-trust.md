# ADR-008: Network security — Zero-trust with WireGuard PTP + Cilium

**Status**: Done (revised 2026-05-24) — all layers implemented: WireGuard PTP mesh,
UFW deny-all, CrowdSec + fail2ban, Cilium NetworkPolicy, Authelia SSO.

**Core principle**: Block ALL inbound ports on bare-metal nodes. The only node
with public ports open is the cloud relay. All administration and inter-node
traffic flows through dedicated WireGuard planes (see `doc/networking.md`).

**Zero-trust network model**:
```
Public internet
     │
     │ ONLY ports 80/443 (web) + 25/465/587/993 (mail)
     ▼
┌─────────────┐
│ Cloud relay │ ← the ONLY node with public ports open
│   (relay)   │   wg-infra-ext :41993 (services)
└──────┬──────┘   wg-relay-admin :41995 (admin SSH to relay)
       │          DNAT :41994 → ctrl (blind, admin WG pipe)
       │
  wg-infra-ext (service traffic)
       │
  ┌────┴────┐
  │  ctrl   │ ← wg-admin :41994, wg-infra-ext :41993, wg-infra-int :41991
  │         │
  └────┬────┘
       │
  Cilium eBPF (encrypted, nodeEncryption: true)
       │
  ┌────┴────┐
  │ worker  │ ← no WG (intra-cluster = Cilium)
  └─────────┘

UFW: deny ALL inbound from internet on bare-metal
SSH: only via wg-admin or wg-relay-admin
K3S API: only via wg-admin subnet
```

**How it works**:
- WireGuard uses 4 isolated planes with independent keys per trust boundary.
- Workers have no WG — intra-cluster uses Cilium (encrypted eBPF tunnels).
- SSH is only accessible via WG admin planes, never via public IP.
- K3S API server binds to admin WG subnet.
- Peer configs are static in Ansible Vault — no control plane dependency.
- WireGuard is kernel-level; survives K3S outages.

**Routing principle — relay is only for public internet traffic**:
- The relay is a blind forwarder (service traffic via `wg-infra-ext`, admin
  traffic via DNAT). It is NOT a hub.
- Admin accessing Grafana? Via `wg-admin` to ctrl (DNAT through relay or direct).
- External MTA delivering email? Goes through relay `wg-infra-ext` (ADR-006).
- Intra-cluster traffic (ctrl↔worker)? Cilium eBPF, no WG involved.
- Inter-cluster (ctrl↔DC2)? Via `wg-infra-int`, no relay involved.

```
                    Public internet traffic
                           │
                    ┌──────▼──────┐
                    │ Cloud relay │ ← wg-infra-ext (services only)
                    │   node      │
                    └──────┬──────┘
                           │
                    wg-infra-ext (HAProxy TCP: mail, HTTPS)
                           │
                    ┌──────▼──┐
                    │  ctrl   │
                    └────┬────┘
                         │
                  Cilium eBPF (encrypted)
                         │
                    ┌────▼────┐
                    │ worker  │  ← no WG, Cilium handles intra-cluster
                    └─────────┘

Admin laptop ──── wg-admin ──── ctrl (via relay DNAT or direct)
```

**Defense in depth — 4 layers**:

| Layer | Tool | Scope |
|-------|------|-------|
| Network | WireGuard planes + UFW deny-all | Zero public exposure on bare-metal |
| Host | CrowdSec + fail2ban | Ban IPs on cloud relay (public ports) |
| Cluster | Cilium NetworkPolicy | Namespace isolation, egress control |
| Application | cert-manager TLS, K8S RBAC, Authelia | Encryption, auth, SSO |

**CrowdSec vs fail2ban**:
- fail2ban: Keep on host level for SSH (via WG mesh) and cloud relay ports.
  Simple, proven, low overhead. With zero-trust, SSH fail2ban is mostly a safety net.
- CrowdSec: Deploy for K8S workloads exposed through the ingress. CrowdSec
  has a K8S bouncer, shares threat intelligence (community blocklists),
  and integrates with the ingress controller. Use for web application protection.
- Strategy: fail2ban on hosts (lightweight safety net), CrowdSec on K8S (smart WAF).

**Additional security measures**:
- Disable default service account automount in all pods
- PodSecurityAdmission `restricted` profile in K3S
- Kernel hardening checker in provisioning playbook
- Ensure all containers run as non-root
- Authelia as SSO/2FA gateway for web services
- OpenSCAP for compliance scanning (evaluate)

**Notes for Trixie**:
- Trixie uses nftables by default. UFW works with the nftables backend
  but existing roles need testing.
- Relay node iptables rules (ADR-006) must be adapted to nftables
  if the relay node also runs Trixie.
