# Authelia SSO

Decision: [ADR-018](adr/018-authelia-sso.md)

## Overview

Authelia provides SSO, OIDC, and forward-auth for the cluster. It runs as a
Helm deployment behind HAProxy Ingress, with file-based users and encrypted
SQLite session storage.

```
Client
  │ HTTPS
  ▼
HAProxy Ingress
  │
  ├── auth.k8s.home ──► Authelia (login portal)
  │
  └── grafana.k8s.home ──► Grafana (native OIDC with Authelia)
```

## Deployment

**Kluctl Helm**: `kluctl/authelia/`, chart `authelia` v0.11.5. Gated by
`args.enable_authelia`. Deployed after ingress + cert-manager, before apps.

## Key configuration

**Users**: file-based (`users-secret.yaml` → Secret mounted at
`/config/users_database.yml`). Admin user in `admins` group.

**Session**: cookie on `auth.{cluster_domain}`, 1h expiry, encrypted SQLite.

**Access control**: default policy `two_factor`; `*.{cluster_domain}` →
`one_factor` for `group:admins`.

**SMTP**: cluster mailserver for notifications/password reset.

## Authentication modes

### Forward auth (HAProxy subrequest)

Used by: whoami. HAProxy annotations on the Ingress:

```yaml
haproxy-ingress.github.io/auth-url: "http://authelia.authelia.svc.cluster.local/api/authz/forward-auth"
haproxy-ingress.github.io/auth-signin: "https://auth.k8s.home/?rd=<original-url>"
haproxy-ingress.github.io/auth-headers-succeed: "Remote-User,Remote-Groups,Remote-Email"
```

HAProxy sends a subrequest to Authelia. On 401, the client is redirected to the
login portal. After authentication, identity headers are forwarded to the
backend.

### Native OIDC

Used by: Grafana, Seafile. These services talk to Authelia OIDC endpoints
directly (`/api/oidc/*`).

| Client ID | Service | Redirect URI | Condition |
|-----------|---------|--------------|-----------|
| `grafana` | Grafana | `https://{grafana_domain}/login/generic_oauth` | Always |
| `seafile` | Seafile | `https://{seafile_domain}/oauth/callback/` | If `enable_seafile` |

Client secrets are stored as bcrypt hashes in SOPS. JWKS private key (RSA 4096)
also in SOPS.

## Secrets (SOPS)

- `authelia_jwt_secret` — JWT HMAC key
- `authelia_session_key` — session encryption key
- `authelia_storage_key` — storage encryption key
- `authelia_oidc_hmac_secret` — OIDC HMAC
- `authelia_oidc_jwks_key` — RSA 4096 private key (base64)
- Per-client secrets (Grafana, Seafile)

## Operations

```sh
just deploy-only authelia/  # redeploy Authelia only
```

The `args.auth_mode` variable (`authelia` | `basic`) controls whether
forward-auth annotations are applied on protected Ingresses.
