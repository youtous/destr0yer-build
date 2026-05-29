# ADR-025: K8S API authentication — certificate via SSH, Authelia for web services

**Status**: Done

**Context**: Two separate auth concerns:
1. K8S API access (`kubectl`) — cluster administration
2. Web service access (Grafana, KopiaUI, Home Assistant, Garage file browser, etc.)

These have different threat models and don't need the same solution.

**Decision**: Certificate kubeconfig for K8S API (via SSH over Headscale).
Authelia SSO for third-party web services (forward auth / OIDC).
No OIDC on the K8S API server — unnecessary complexity for 1-2 admins.

**K8S API auth (cluster administration)**:

```
laptop → Tailscale mesh → SSH to control plane node
  → kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml
```

- Client certificate auth, generated at K3S install time
- Kubeconfig stays on the node — never copied off
- SSH access controlled by Headscale mesh (must be on the mesh)
- K3S audit logging captures all API calls
- If Headscale registration is down: existing WireGuard tunnels persist
- If all mesh is down: WireGuard point-to-point fallback (ADR-005)

This is simple, has zero dependencies on Authelia or OIDC, and is
sufficient for 1-2 admins. If multi-user becomes necessary later,
OIDC can be added without changing the existing certificate path.

**Web service auth (Authelia SSO)**:

Authelia remains for all third-party web services accessed through
the ingress. These services don't have consistent built-in auth,
and Authelia provides unified SSO + 2FA across all of them.

**Three-tier access model**:

| Tier | Access from | Auth | Services |
|------|------------|------|----------|
| **Protocol endpoints** | Anywhere (relay DNAT) | Protocol-native | IMAP, SMTP, S3 API |
| **User web UIs** | Anywhere (relay DNAT) | Authelia 2FA | Webmail, Garage file browser |
| **Admin dashboards** | Headscale mesh only | Mesh + built-in auth | Grafana, KopiaUI, K8S Dashboard |

**Why this split**: A phone on a different VPN (not Tailscale) can access
email via native IMAP client and files via S3 client — protocol-level auth,
no Tailscale needed. Webmail and Garage browser are also accessible from
anywhere via the relay, protected by Authelia 2FA. Admin dashboards remain
mesh-only (more sensitive, fewer access needs).

**IP allowlisting on all public endpoints**: Even with protocol-level auth
and Authelia 2FA, the relay's nftables rules restrict connections to known
IP addresses/ranges only. Unknown IPs are dropped before reaching any service.

```
# Relay nftables (applied to DNAT rules)
# Only allow known IPs to reach mail/web/S3 ports
nft add set inet filter allowed_ips { type ipv4_addr\; flags interval\; }
nft add element inet filter allowed_ips {
  <home-ip>/32,
  <work-ip>/32,
  <mobile-carrier-range>/16,
  <vpn-exit-ip>/32
}
# DNAT only for allowed IPs
nft add rule inet nat prerouting ip saddr @allowed_ips tcp dport { 25,465,587,993,443 } dnat to <bare-metal-wg-ip>
```

For SMTP inbound (port 25), allow all IPs — other mail servers need to
reach you. For user-facing ports (465, 587, 993, 443), restrict to known IPs.
This adds a layer before any auth is even attempted — unknown IPs never
see the service. Update the allowlist via Ansible when IPs change.

| Service | Tier | Auth | Access |
|---------|------|------|--------|
| IMAP/SMTP (docker-mailserver) | Protocol | IMAP password | Anywhere via relay |
| Garage S3 API | Protocol | HMAC key | Anywhere via relay |
| Webmail (SnappyMail) | User web | Authelia 2FA | Anywhere via relay |
| Garage file browser | User web | Authelia 2FA | Anywhere via relay |
| Gatus (public status) | User web | None (read-only) | Anywhere via relay |
| Grafana | Admin | OIDC (Authelia) | Mesh only |
| KopiaUI | Admin | Forward auth (Authelia) | Mesh only |
| Home Assistant | Admin | Forward auth (Authelia) | Mesh only |
| K8S Dashboard | Admin | Forward auth (Authelia) | Mesh only |

Forward auth pattern: ingress checks with Authelia before forwarding
to the backend. If not authenticated → redirect to Authelia login (2FA).

**Separation of concerns**:

```
K8S API (cluster ops)         Web services (app access)
┌───────────────────┐         ┌───────────────────────┐
│ SSH + certificate │         │ Authelia SSO + 2FA    │
│ kubeconfig        │         │ forward auth / OIDC   │
│                   │         │                       │
│ No Authelia       │         │ Grafana, HA, Kopia,   │
│ No OIDC           │         │ Garage, Dashboard     │
│ No browser needed │         │                       │
│                   │         │ If Authelia is down:   │
│ If mesh is down:  │         │ web services locked   │
│ WireGuard fallback│         │ but K8S API still works│
└───────────────────┘         └───────────────────────┘
```

If Authelia is compromised: web services are exposed, but the K8S API
is unaffected (no OIDC dependency). Blast radius is limited to app-level
access, not cluster administration.

**Implementation**:
1. K8S API: no changes needed — K3S certificate auth works out of the box
2. Authelia: deploy via Kluctl in `security/authelia/`
3. Configure Authelia as OIDC provider for Grafana
4. Configure forward auth middleware in ingress for other services
5. Authelia users file in Ansible Vault
6. No `oidc-issuer-url` args on K3S API server (keep it simple)
