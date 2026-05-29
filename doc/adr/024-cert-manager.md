# ADR-024: Certificate management — centralized cert-manager + split DNS

**Status**: Decided (internal-ca implemented, Let's Encrypt deferred to prod)

**Context**: Multiple clusters need TLS certificates. Wildcard certs require
DNS-01 challenge, which needs DNS provider API access (Cloudflare). The
Cloudflare API token should exist in exactly ONE place, not scattered across
every cluster.

**Key constraint**: The Cloudflare API token (even scoped) should NEVER be in
any K3S cluster. If the cluster is compromised, the attacker should not be able
to modify DNS records.

**Decision**: CNAME delegation to deSEC for DNS-01 challenges. Cloudflare
credentials are never in the cluster. One-time manual CNAME setup in Cloudflare,
then cert-manager talks only to deSEC.

**Options evaluated**:

| | deSEC delegation | Self-hosted acme-dns | Direct Cloudflare |
|---|---|---|---|
| Cloudflare token in K3S | **No** | **No** | Yes |
| Manual Cloudflare setup | Once (CNAME) | Once (CNAME) | Once (token) |
| Self-hosted component | None | acme-dns pod | None |
| If credential leaks | Can only issue certs | Can only issue certs | Can modify DNS zone |
| Maintenance | Zero | Keep acme-dns up | Zero |

deSEC wins: zero Cloudflare exposure, zero self-hosting, one-time manual CNAME.

**deSEC caveat** (Perplexity finding): deSEC has a minimum TTL of 3600s (1 hour).
DNS-01 challenges may timeout because Let's Encrypt validators query stale
resolvers before propagation completes. Workaround:
- cert-manager already queries authoritative nameservers directly by default
  (no need for `--dns01-recursive-nameservers-only` which can actually be worse)
- Increase `dns01` solver `propagationTimeout` in the ClusterIssuer if needed
- Consider self-hosted acme-dns as fallback if deSEC proves unreliable

**CNAME delegation requirement**: cert-manager does NOT follow CNAME records
by default. The solver MUST set `cnameStrategy: Follow`, otherwise the CNAME
`_acme-challenge.pub.cluster.example.com → _acme-challenge.zone1.dedyn.io`
is ignored and cert-manager tries to write the TXT on the wrong zone.

**Split DNS architecture**:

```
┌─────────────────────────────────────────────────────────┐
│ Public DNS (Cloudflare)                                 │
│                                                         │
│ example.com         A     → relay public IP             │
│ mail.example.com    A     → relay public IP             │
│ *.pub.example.com   CNAME → relay.example.com           │
│                                                         │
│ (managed manually or via Ansible cloudflare module)      │
│ (NO external-dns operator — overkill for static setup)  │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│ Internal DNS (CoreDNS in K3S + Headscale MagicDNS)     │
│                                                         │
│ *.k8s.home         → Cilium service IPs (CoreDNS)      │
│ node-a.mesh        → 100.x.y.z (Headscale MagicDNS)   │
│ grafana.k8s.home   → cluster-internal, never public    │
│                                                         │
│ (Cloudflare not involved — no token needed)             │
└─────────────────────────────────────────────────────────┘
```

**Certificate strategy — 3 tiers**:

| Tier | Scope | Issuer | Challenge | Where |
|------|-------|--------|-----------|-------|
| **Public wildcard** | `*.pub.example.com` | Let's Encrypt | DNS-01 via deSEC | Each cluster independently |
| **Internal CA** | `*.k8s.home` | Self-signed CA (cert-manager) | None | Each cluster locally |
| **mTLS (pod-to-pod)** | Pod-to-pod | Cilium transparent encryption | None (auto) | Each cluster |

**Key simplification** (Perplexity finding): No "primary cluster generates
and exports" pattern. **Each cluster independently issues its own wildcard cert.**
This eliminates the coupling and ordering dependency (cluster A must be healthy
for cluster B to renew).

Requirements for independent issuance:
- Share the same ACME account key across clusters (via Ansible Vault)
- Use separate deSEC CNAME targets per cluster to avoid TXT record conflicts
- Rate limits are per domain+account — staggered 60-day renewals are fine

```
One-time manual setup in Cloudflare (never changes, DNS-only/non-proxied):
  _acme-challenge.pub.cluster1.example.com  CNAME  _acme-challenge.zone1.dedyn.io
  _acme-challenge.pub.cluster2.example.com  CNAME  _acme-challenge.zone2.dedyn.io

Each cluster independently:
  cert-manager → deSEC API → TXT record → Let's Encrypt validates
  (no dependency on other clusters)
```

**Non-K3S hosts** (relay node, backup node, DB host):
Use `lego` (Go ACME client) as a systemd timer — single binary, no daemon,
CNAME delegation to deSEC works natively. Zero K3S dependency.

```sh
# lego systemd timer on relay/backup node
lego --email admin@example.com \
     --dns desec \
     --domains "relay.example.com" \
     run
```

**Internal services** — HTTPS everywhere, even behind the mesh:
Even inside the WireGuard mesh, TLS at the application layer is needed for
services handling credentials (Authelia, Grafana, KopiaUI). Without it, any
compromised mesh peer can MITM sessions via ARP spoofing on the LAN segment.

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: internal-ca
spec:
  ca:
    secretName: internal-ca-key-pair
```

Distribute the internal CA cert to Headscale-connected devices via Ansible.
Browsers trust the CA — no warnings.

**MariaDB TLS** — cert-manager replaces `generate-X509-certificate.rb`:
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: mariadb-tls
spec:
  secretName: mariadb-tls-secret
  issuerRef:
    name: internal-ca
    kind: ClusterIssuer
  dnsNames:
    - mariadb.internal.example.com
  duration: 8760h
  renewBefore: 720h
```
Ansible copies cert/key from the K8S Secret to the DB host. Auto-renewal.

**DNS management — no operator needed**:
- Public DNS records are mostly static (relay IP rarely changes)
- Managed via Ansible `community.general.cloudflare_dns` module or manually
- No `external-dns` operator — it's designed for dynamic cloud environments
  where services come and go. Our services are static.
- If the relay IP changes: update ONE A record in Cloudflare, all CNAMEs follow

**Headscale for internal access**:
- Internal services are NOT in Cloudflare DNS at all
- Headscale MagicDNS resolves node names: `node-a.tailnet` → `100.x.y.z`
- CoreDNS in K3S resolves service names: `grafana.k8s.home` → cluster IP
- Devices on the mesh can reach both via split DNS:
  - `.tailnet` → Headscale resolver
  - `.k8s.home` → CoreDNS (forwarded via Headscale)
  - Everything else → upstream (Cloudflare 1.1.1.1 via dnscrypt-proxy)

**Security**:
- deSEC token can only manage challenge TXT records (not your main DNS)
- Stored in Ansible Vault, deployed to cert-manager namespace per cluster
- Kyverno policy: only cert-manager pods can read the secret
- If compromised: attacker can issue certs (mitigated by CAA DNS records)
- Cloudflare credentials: NEVER in any cluster, NEVER in any secret
- Cloudflare CNAME records MUST be non-proxied (DNS-only / grey cloud) —
  proxied CNAMEs break deSEC challenge resolution

**DNS management — manual Cloudflare setup (scales fine)**:
One-time setup per cluster, infrequent changes:
1. A record for relay IP
2. CNAME `_acme-challenge.pub.clusterN` → deSEC (non-proxied)
3. CAA record restricting cert issuance to Let's Encrypt only
4. New service: CNAME to existing relay hostname

**DNS registration strategy**:
- Use wildcard DNS records (`*.pub.example.com`) pointing to relay for all
  public-facing services. Avoids per-service DNS management.
- Internal: `*.k8s.home` resolved by CoreDNS — no public DNS needed.
- One wildcard cert per cluster covers all public Ingresses.

**Current state (dev)**:
- ✅ `internal-ca` ClusterIssuer deployed (self-signed CA for `*.k8s.home`)
- ✅ All Ingresses use `cert-manager.io/cluster-issuer: cluster-issuer` annotation
- ⏳ Let's Encrypt via deSEC: deferred until production deployment
  (requires deSEC account creation and one-time Cloudflare CNAME setup)

**Implementation**:
1. ~~Configure internal CA ClusterIssuer for `*.k8s.home`~~ ✅ Done
2. ~~CoreDNS custom zone for `*.k8s.home`~~ ✅ Done
3. Create deSEC account + per-cluster delegated zones (prod)
4. Add wildcard CNAME records in Cloudflare (non-proxied) + CAA record (prod)
5. Share ACME account key across clusters via Ansible Vault (prod)
6. Deploy cert-manager deSEC webhook + ClusterIssuer (prod)
7. Each cluster has its own wildcard Certificate (prod)
8. Install `lego` on non-K3S hosts (relay, backup) via Ansible (prod)
9. Use cert-manager Certificate CRD for MariaDB TLS (replaces Ruby script)
10. Distribute internal CA cert to Headscale-connected devices
