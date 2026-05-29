# ADR-018: Identity and access management — Authelia SSO

**Status**: Done

**Context**: Every service has its own authentication silo — Grafana has local
users, Garage has S3 API keys, Headscale has API keys, K8S has service accounts,
SSH has ed25519 keys. Managing credentials across N services for M users is
fragile and doesn't scale.

We need:
- Single sign-on (SSO) across all web services
- Role-based access (admin vs operator vs user)
- 2FA enforcement
- Standard protocol so services don't need custom auth code

**Decision**: Deploy Authelia as the unified identity provider.

**Why Authelia**:
- ~30 MB RAM (fits cloud free tier)
- OIDC provider since v4.38 — services authenticate via standard OpenID Connect
- 2FA: TOTP + WebAuthn/passkeys
- File-based user store (YAML) — no database needed for a small team
- Forward auth for services without native OIDC — ingress sends auth to Authelia
- Active project, well-documented, widely used in self-hosting

**User roles**:

| Role | K8S access | Services | Example |
|------|-----------|----------|---------|
| `admin` | cluster-admin | All services, full config | You |
| `operator` | namespace-scoped | Manage Garage buckets, Headscale nodes, Grafana dashboards | Trusted collaborator |
| `user` | None | Own S3 storage, webmail, file browser | Family/friends |

**How each service authenticates**:

| Service | Auth method | How it works |
|---------|------------|-------------|
| Grafana | OIDC | Native OIDC integration, auto-create users from Authelia |
| ~~ArgoCD~~ | ~~OIDC~~ | Not used — Kluctl replaces ArgoCD (ADR-013) |
| Headscale | OIDC | Native OIDC support for web UI and node registration |
| Garage web UI | Forward auth | Ingress sends request to Authelia before reaching FileBrowser/Filestash |
| Garage S3 API | API keys | S3 access keys managed per-user via Garage admin. Authelia not involved for S3 protocol (HMAC auth is S3-native) |
| K8S Dashboard | OIDC | OIDC token passed as bearer, RBAC maps groups to permissions |
| Gatus | Forward auth | Read-only status page, optional auth for admin |
| Loki/Prometheus | Forward auth | Behind ingress, Authelia protects the UI |
| Mail webmail | Forward auth | Webmail behind Authelia, IMAP credentials separate (SMTP auth is protocol-level) |
| SSH | SSH keys | Not through Authelia — SSH keys managed by Ansible, access via Headscale mesh only |

**Forward auth pattern** (for services without native OIDC):
```
User → Ingress (Cilium/HAProxy) → Authelia check
                                      │
                            ┌─────────┴──────────┐
                            │                    │
                        authenticated         not authenticated
                            │                    │
                            ▼                    ▼
                        forward to           redirect to
                        backend service      Authelia login page
```

**Authelia user file example** (`users_database.yml`):
```yaml
users:
  alice:
    displayname: "Alice"
    email: alice@domain.com
    groups:
      - admins
      - operators
    password: "$argon2id$..."  # hashed

  bob:
    displayname: "Bob"
    email: bob@domain.com
    groups:
      - users
    password: "$argon2id$..."
```

This file is Ansible Vault-encrypted and deployed by the `k3s_authelia` role.
Authelia maps groups to access rules:

```yaml
access_control:
  default_policy: deny
  rules:
    - domain: "grafana.k8s.example.com"
      policy: one_factor
      subject: "group:operators"

    - domain: "*.k8s.example.com"
      policy: two_factor
      subject: "group:admins"

    - domain: "files.k8s.example.com"
      policy: one_factor
      subject: "group:users"
```

**Garage-specific user management**:
The "dedicated Garage user" scenario works like this:
1. User authenticates via Authelia SSO (OIDC or forward auth)
2. Their access to the web file browser is controlled by Authelia groups
3. Their S3 API access uses per-user Garage access keys (created by admin
   via `garage key create <username>`)
4. Bucket-level permissions are set via Garage's `garage bucket allow`
5. The user manages their files via S3 API or web UI — no K8S access needed

**Deployment**: Bare-metal only (privacy/security critical — see ADR-010).
Authelia login page is exposed to the internet via relay DNAT through
WireGuard, same pattern as the mail server. The relay node never sees credentials.

**Implementation**:
1. Create role `k3s_authelia` deploying Authelia via Helm on bare-metal nodes
2. Configure Authelia as OIDC provider
3. Expose Authelia login endpoint via relay DNAT (port 443, SNI-routed)
4. Configure forward auth middleware in Cilium Gateway API / HAProxy
5. Add OIDC client configs for Grafana, Headscale
6. Vault-encrypt the users database file
7. Store Authelia session/encryption secrets in K8S Secrets (vault-managed)

**Deployment order**: After ingress (needs forward auth middleware) and
cert-manager (needs TLS), before application services that depend on auth.
Fits in `04-security.yml`.
