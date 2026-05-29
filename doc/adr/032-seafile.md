# ADR-032: Seafile for file sync/share (replaces Nextcloud)

**Status**: Done — client-side encryption to be enabled on sensitive libraries

**Context**: A file sync & share solution is needed for personal documents, photos,
and shared folders. Nextcloud was used previously (Docker Swarm era) but is heavy
(~500 MB+ RAM, PHP-FPM, MariaDB, Redis) and has a large attack surface with
frequent CVEs. We need something lighter that integrates with our existing stack.

**Requirements**:
- S3 backend (Garage) for object storage — no local filesystem dependency
- Client-side encryption for sensitive libraries
- SSO via Authelia (OIDC)
- Web UI + desktop/mobile sync clients
- Reasonable resource footprint for self-hosting
- Active maintenance, no abandonware

**Decision**: Deploy Seafile with Garage S3 backend, Authelia OIDC, and client-side encryption.

**Seafile vs Nextcloud**:

| | Seafile | Nextcloud |
|---|---|---|
| Language | Python + C (server) | PHP |
| RAM usage | ~100-150 MB | ~500 MB+ |
| S3 backend | Native (storage backend) | Plugin (primary storage) |
| Client-side encryption | Built-in per-library | Not native (E2EE beta, unreliable) |
| OIDC/SAML SSO | Native (OAuth2, SAML) | Plugin |
| File sync clients | Win/Mac/Linux/iOS/Android | Win/Mac/Linux/iOS/Android |
| WebDAV | Yes | Yes |
| Calendar/Contacts | No | Yes (CalDAV/CardDAV) |
| Office editing | Collabora/OnlyOffice plugin | Collabora/OnlyOffice plugin |
| Attack surface | Smaller (focused on files) | Large (app ecosystem) |

**Architecture**:
```
┌──────────────┐     ┌─────────────┐     ┌──────────────┐
│  Seafile     │────▶│  Garage S3  │     │  MariaDB     │
│  (seahub +   │     │  (objects)  │     │  (metadata)  │
│   seafile-   │     └─────────────┘     └──────────────┘
│   server)    │                                │
└──────┬───────┘                                │
       │ OIDC                                   │
┌──────▼───────┐                                │
│  Authelia    │                                │
│  (SSO)       │                                │
└──────────────┘                                │
       │                                        │
┌──────▼───────┐                                │
│  HAProxy     │◀───────────────────────────────┘
│  Ingress     │
└──────────────┘
```

Components:
- **seahub** (Django web UI) + **seafile-server** (file operations) in one pod
- **MariaDB** sidecar for metadata (or shared MariaDB if later needed)
- **Garage S3** as storage backend (configured in `seafile.conf`)
- **Authelia OIDC** for authentication (no local user DB)
- **Encrypted libraries**: users opt-in per library, key never leaves client
- **Ingress**: HAProxy with TLS via cert-manager

**Kluctl deployment** (planned):
```
kluctl/apps/seafile/
├── helm-chart.yaml (or raw manifests)
├── helm-values.yaml
├── mariadb.yaml
└── ingress.yaml
```

**Secrets (SOPS)**:
- `secrets.seafile_admin_password`
- `secrets.seafile_db_password`
- `secrets.seafile_s3_access_key` / `secrets.seafile_s3_secret_key`
- `secrets.seafile_oidc_client_secret`

**Alternatives considered**:
- **Nextcloud**: Too heavy, too many CVEs, PHP stack doesn't align with our infra
- **Syncthing**: No web UI, P2P only, no S3 backend, no server-side access
- **MinIO Console**: Not a file sync tool, just S3 browser
- **Filestash**: Unmaintained, JavaScript, no native sync clients

**Consequences**:
- CalDAV/CardDAV not included — evaluate Radicale separately if needed
- MariaDB adds ~100 MB RAM overhead (metadata only, small DB)
- Desktop clients are mature (cross-platform, been around since 2012)
- Library encryption means server-side search is disabled for encrypted libs

**Implementation plan**:
- [ ] Scaffold `kluctl/apps/seafile/` deployment
- [ ] Deploy Seafile with Garage S3 backend
- [ ] Configure Authelia OIDC client for Seafile
- [ ] TLS Ingress via cert-manager
- [ ] Test client-side encryption with desktop client
- [ ] Configure Reloader for cert renewal
- [ ] Document backup strategy (MariaDB dump + S3 replication handles the rest)
