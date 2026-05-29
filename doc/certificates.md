# Certificate Management

Decision: [ADR-024](adr/024-cert-manager.md)

## Architecture

Three certificate tiers, no cross-cluster dependency:

| Tier | Scope | Issuer | Tool |
|------|-------|--------|------|
| Public wildcard | `*.pub.cluster.example.com` | Let's Encrypt (DNS-01 via deSEC) | cert-manager (per cluster) |
| Internal CA | `*.k8s.home` | Self-signed CA | cert-manager (per cluster) |
| Non-K3S hosts | Relay node, backup node | Let's Encrypt (DNS-01 via deSEC) | `lego` systemd timer |

Each cluster independently issues its own certs. No "primary cluster
exports to others" pattern. Shared ACME account key in Ansible Vault.

## Centralized ClusterIssuer — `cluster-issuer`

All Kluctl units request certificates from a single well-known
ClusterIssuer named **`cluster-issuer`**. The backend (self-signed CA
or Let's Encrypt) is controlled by one variable in the Kluctl target:

```yaml
# kluctl/.kluctl.yaml or kluctl/targets/<env>.yaml
certmanager_issuer_type: "internal-ca"   # self-signed CA chain
# certmanager_issuer_type: "letsencrypt" # ACME DNS-01 via deSEC
```

When `internal-ca`, the template creates a bootstrap self-signed issuer,
generates a CA certificate, and exposes `cluster-issuer` backed by that CA.
When `letsencrypt`, it creates `cluster-issuer` backed by ACME with DNS-01
challenge solving via deSEC webhook (see below).

The template lives in `kluctl/security/cert-manager/issuers/cluster-issuer.yaml.j2`.

### Requesting a certificate from any unit

Components never need to know the issuer backend. Just reference
`cluster-issuer`:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: my-app-tls
  namespace: my-namespace
spec:
  secretName: my-app-tls-secret
  issuerRef:
    name: cluster-issuer
    kind: ClusterIssuer
  dnsNames:
    - my-app.k8s.home
```

Or via ingress annotation:

```yaml
annotations:
  cert-manager.io/cluster-issuer: cluster-issuer
```

## Public certs — DNS-01 via deSEC CNAME delegation

Cloudflare API token never enters any cluster. One-time manual CNAME
in Cloudflare (non-proxied/grey cloud) delegates the challenge to deSEC:

```
_acme-challenge.pub.cluster1.example.com  CNAME  _acme-challenge.zone1.dedyn.io
```

cert-manager in each cluster talks to deSEC API only. If the deSEC token
leaks, the attacker can only issue certs (mitigated by CAA records limiting
to Let's Encrypt only).

### Enabling Let's Encrypt with deSEC

Set the following in the Kluctl target:

```yaml
# kluctl/.kluctl.yaml — target args
certmanager_issuer_type: "letsencrypt"
certmanager_acme_email: "admin@example.com"
certmanager_acme_server: "https://acme-v02.api.letsencrypt.org/directory"
certmanager_desec_group_name: "acme.example.com"
certmanager_desec_token_secret_name: "desec-token"
```

Add the deSEC API token to the SOPS-encrypted target vars:

```yaml
# kluctl/targets/<env>.enc.yaml
secrets:
  desec_token: "<your-desec-api-token>"
```

This automatically:
1. Deploys the deSEC webhook (`kluctl/security/cert-manager/desec-webhook/`)
2. Creates a K8S Secret with the deSEC API token
3. Configures cert-manager to use deSEC authoritative nameservers
   (`ns1.desec.io`, `ns2.desec.org`) to avoid stale cache issues (min TTL 3600s)
4. Creates `cluster-issuer` as an ACME ClusterIssuer with DNS-01 solver

### One-time Cloudflare setup

Per cluster, add these DNS records (non-proxied / grey cloud):

```
_acme-challenge.pub.<cluster>.example.com  CNAME  _acme-challenge.<zone>.dedyn.io
```

Add a CAA record restricting cert issuance to Let's Encrypt:

```
example.com  CAA  0 issue "letsencrypt.org"
```

### Security

- deSEC token scoped to challenge TXT records only
- Stored in SOPS-encrypted vars, deployed as K8S Secret in `cert-manager` namespace
- Cloudflare credentials never enter any cluster
- Webhook RBAC: only cert-manager SA can access the deSEC token Secret

## Internal certs — self-signed CA

cert-manager creates a local CA per cluster (when
`certmanager_issuer_type: internal-ca`). Internal services
(`grafana.k8s.home`, `authelia.k8s.home`) get certs from this CA.
Distribute the CA cert to Headscale-connected devices via Ansible.

## Non-K3S hosts — lego systemd timer

The relay node and backup node are not K3S members. They use `lego`
(Go ACME client, single binary) with the same deSEC CNAME delegation:

```sh
lego --email admin@example.com --dns desec --domains "relay.example.com" run
```

Renewal via systemd timer. Zero K3S dependency.

## HTTPS inside the mesh

Even behind WireGuard, TLS at the application layer is needed for services
handling credentials (Authelia, Grafana, KopiaUI). A compromised mesh peer
can MITM sessions via ARP spoofing without TLS. Use HTTPS everywhere
internally — the self-signed CA has near-zero operational overhead.

## Pod-to-pod mTLS

Handled by Cilium transparent encryption (WireGuard mode). No application-level
TLS needed for inter-pod communication.

See [ADR-008](adr/008-network-zero-trust.md) (network security) for full rationale.
