# ADR-008: Network security — Zero-trust with WireGuard PTP + Cilium

**Status**: Done (revised 2026-05-24) — all layers implemented: WireGuard PTP mesh,
UFW deny-all, CrowdSec + fail2ban, Cilium NetworkPolicy, Authelia SSO.

**Core principle**: Block ALL inbound ports on bare-metal nodes. The only node
with public ports open is the cloud relay. All administration and inter-node
traffic flows through the WireGuard PTP mesh.

**Zero-trust network model**:
```
Public internet
     │
     │ ONLY ports 80/443 (web) + 25/465/587/993 (mail)
     ▼
┌─────────────┐
│ Cloud relay │ ← the ONLY node with public ports open
│   (relay)   │
└──────┬──────┘
       │ WireGuard PTP mesh (10.99.99.0/24)
       │ (nodes connect OUTBOUND, no inbound needed)
  ┌────┴────┐
  │         │
  ▼         ▼
bare-metal  bare-metal
  nodes       nodes
  │              │
  └── UFW: deny ALL inbound from internet
      SSH: only via WireGuard mesh (10.99.99.0/24)
      K3S API: only via WireGuard mesh
      Monitoring: only via WireGuard mesh
```

**How it works**:
- All infra nodes are WireGuard peers in a static mesh (Ansible-managed).
- SSH is only accessible via WG IP (10.99.99.x), never via public IP.
- K3S API server binds to WG interface.
- Peer configs are static in Ansible Vault — no control plane dependency.
- WireGuard is kernel-level; survives K3S outages.

**Routing principle — the relay node is only for public internet traffic**:
- The WireGuard mesh is **peer-to-peer**. Nodes connect directly to each other,
  not through the relay node. The relay node is NOT a hub.
- The relay node is only involved when traffic comes FROM or goes TO the public
  internet (web requests, inbound/outbound email).
- Admin accessing Grafana? Direct WG connection to bare-metal, bypasses relay.
- Alloy on relay shipping logs to Loki? Direct WG to bare-metal.
- K3S API calls between nodes? Direct WG mesh.
- External MTA delivering email? Goes through relay (ADR-006).

```
                    Public internet traffic
                           │
                    ┌──────▼──────┐
                    │ Cloud relay │ ← only for public-facing services
                    │   node      │
                    └──────┬──────┘
                           │
            WireGuard PTP mesh (static peers, direct connections)
                    ┌──────┴──────┐
                    │             │
             ┌──────▼──┐   ┌─────▼───┐
             │ BM-A    │◄─►│ BM-B    │  ← direct mesh, relay not involved
             │(ctrl)   │   │(worker) │
             └─────────┘   └─────────┘

Admin laptop ──── WireGuard client ──── direct to BM-A:Grafana
                  (or Headscale in future, see ADR-005 Tier 2)
```

**Defense in depth — 4 layers**:

| Layer | Tool | Scope |
|-------|------|-------|
| Network | WireGuard PTP mesh + UFW deny-all | Zero public exposure on bare-metal |
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
