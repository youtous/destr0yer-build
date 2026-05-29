# ADR-029: Additional services (future)

**Status**: Done (cleaned 2026-05-26)

Services beyond core infrastructure. Items migrate to their own ADRs once promoted.

## Deployed (done)

| Item | ADR / Location | Status |
|------|---------------|--------|
| Home Assistant | ADR-019, `kluctl/home/homeassistant/` | ✅ Deployed |
| Mosquitto MQTT | ADR-031, `kluctl/home/mosquitto/` | ✅ Deployed |
| Zigbee2MQTT | ADR-031, `kluctl/home/zigbee2mqtt/` | ✅ Deployed |
| Authelia SSO | ADR-018, `kluctl/authelia/` | ✅ Deployed |
| parsedmarc | `kluctl/mail/parsedmarc/` | ✅ Deployed |
| Seafile | ADR-030, `kluctl/apps/seafile/` | ✅ Deployed |
| MariaDB Operator | `kluctl/database/` | ✅ Deployed |

## Next candidate

| Item | Category | Notes |
|------|----------|-------|
| Vaultwarden | Security | Self-hosted Bitwarden. SSO via Authelia OIDC. See architecture notes below. |

## Backlog (evaluate later)

| Item | Category | Notes |
|------|----------|-------|
| ntfy | Notifications | Self-hosted push notifications. See `doc/proposal-ntfy-push-notifications.md`. |
| External Secrets Operator | Security | ESO syncs Vaultwarden secrets → K8S Secrets. Deploy after Vaultwarden. |
| Renovate | Automation | Automated version bump PRs for images/charts/deps. |

## Superseded / removed

- Sentry → overkill for homelab, Loki + Grafana alerting suffices
- Mosh → nice-to-have, install via system_packages when needed
- PTP instead of NTP → not needed for homelab
- Restic → superseded by Kopia (ADR-022)
- All Swarm-specific items (Caddy, Docker socket, GlusterFS, etc.)
- Nextcloud → superseded by Seafile (ADR-030)
- Rainloop → superseded by docker-mailserver webmail (planned)

---

## Vaultwarden architecture notes

**Deployment**: Kluctl component `security/vaultwarden/`, single Deployment + PVC
(SQLite), namespace `security`. Protected by Authelia forward auth at ingress
level + native Vaultwarden auth (double layer).

**SSO**: Vaultwarden supports OIDC since v1.32. Configure Authelia as OIDC
provider → single login for Vaultwarden + Grafana + all protected services.

**Use cases**:

| Use case | Tool | Why |
|----------|------|-----|
| Daily passwords (web, services) | Vaultwarden | Sync, autofill, browser ext, mobile |
| API tokens, webhook secrets | Vaultwarden | Shared via organizations/collections |
| Inter-service credentials (future) | Vaultwarden CLI (`bw get`) | Scripts, CI/CD, automation |
| Infra break-glass (vault pwd, SOPS key, root recovery) | Keepass `.kdbx` (offline) | Always available, zero cluster dependency |
| Ansible Vault password | Keepass → env var | Never in Vaultwarden (chicken-and-egg) |

**Backup**: PVC backed up by Velero to Garage S3. Additionally, Vaultwarden
supports native JSON export — schedule a CronJob to export to a Kopia-backed
path for independent recovery.

**Priority class**: `cluster-infra` (same as Authelia, cert-manager).
