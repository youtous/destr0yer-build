# Proposal: ntfy — Self-Hosted Push Notifications

Status: Under test (2026-05-27)
Related: ADR-006 (mail), ADR-008 (security), doc/security.md

---

## Problem

Email is the current notification channel for all alerts (Alertmanager, Gatus,
testssl, fail2ban, notify_login). Two issues:
1. Email is too slow for critical events — SSH logins, cluster failures, and
   security incidents need immediate push notifications on mobile.
2. **Email depends on the mailserver** — if the mailserver pod is down or the
   mail namespace is unhealthy, ALL email-based alerts are silenced. ntfy is
   the independent fallback channel that survives mailserver outages.

## What is ntfy

[ntfy](https://ntfy.sh/) is a simple HTTP-based pub-sub notification service.
Self-hostable, single Go binary, ~15 MB RAM. Clients available for Android
(F-Droid/Play Store), iOS, and web. Messages sent via `curl` or any HTTP POST.

```sh
# Send a notification
curl -d "SSH login on ctrl from 10.99.99.1" https://ntfy.k8s.home/ssh-alerts

# With priority and tags
curl -H "Priority: urgent" -H "Tags: skull" \
  -d "Cluster ctrl is DOWN" https://ntfy.k8s.home/cluster-critical
```

---

## Use Cases

### UC-1: Critical infrastructure alerts (immediate push)

| Event | Source | Current channel | With ntfy |
|-------|--------|----------------|-----------|
| SSH login on any node | `notify_login` role (Ansible) | Email (postfix relay) | Push (urgent priority) |
| Cluster node down | Prometheus Alertmanager | Email | Push (urgent) + email |
| Pod CrashLoopBackOff | Prometheus Alertmanager | Email | Push (high) |
| Certificate expiring | cert-manager / Alertmanager | Email | Push (high) |
| CrowdSec ban triggered | CrowdSec LAPI | Log only | Push (default) |
| fail2ban ban triggered | fail2ban action | Email | Push (default) + email |
| Backup failed | Kopia systemd timer | Email (on-failure) | Push (urgent) + email |
| Health check down | Gatus | Email | Push (high) + email |
| TLS issue detected | testssl CronJob | Email | Push (default) |
| Disk >90% | Prometheus Alertmanager | Email | Push (high) |

**Principle**: Push for attention, email for audit trail. Both channels for
critical events.

### UC-2: Authelia 2FA push notifications

Authelia currently supports Duo (proprietary) for push-based 2FA. There is an
[open feature request (#7647)](https://github.com/authelia/authelia/issues/7647)
for ntfy/UnifiedPush support — status: `needs-design`, not yet implemented.

**Current workaround**: Use TOTP (authenticator app) for 2FA. Monitor the
Authelia issue for native ntfy support.

**Future (when implemented)**:
1. User logs into `auth.k8s.home`
2. Authelia sends push to ntfy topic `authelia-2fa-<user>`
3. User taps "Approve" on ntfy mobile app
4. Authelia validates → session created

### UC-3: Cluster-to-admin real-time notifications

| Scenario | ntfy topic | Priority |
|----------|-----------|----------|
| WireGuard mesh peer unreachable | `wg-mesh` | high |
| Kluctl deploy completed/failed | `deploy-status` | default |
| Kyverno policy violation (Enforce mode) | `policy-violations` | high |
| New K3S node joined cluster | `cluster-events` | default |
| etcd snapshot completed | `backup-status` | low |

### UC-4: Cross-cluster notifications

With the multi-zone architecture (ADR-010), each cluster pushes to the same
ntfy instance (or federated instances). The admin gets a unified notification
stream from all clusters.

```
Home-1 cluster → ntfy.k8s.home/cluster-home1-alerts
Home-2 cluster → ntfy.k8s.home/cluster-home2-alerts
Cloud relay    → ntfy.k8s.home/relay-alerts
```

If ntfy runs on Home-1, other clusters reach it via WireGuard mesh. If ntfy
is on the relay, all clusters reach it directly.

---

## Architecture

### Deployment: two variants depending on relay resources

#### Variant A: ntfy on home cluster only (relay minimal / no K3S)

ntfy runs on the home cluster. Mobile clients access it via relay SNI proxy
(`ntfy.example.com` → home cluster via WireGuard). Relay never sees content.

If home cluster is down, ntfy is down — email + healthchecks.io take over.

Best for: minimal relay (systemd-only, cheap VPS, limited resources).

#### Variant B: ntfy on relay K3S with sanitized messages (recommended)

ntfy runs on the relay K3S. Survives home cluster outages. Mobile clients
connect directly to the relay public IP — no SNI hop, lower latency.

**Privacy constraint**: the relay is untrusted cloud. All notification
content must be **sanitized** — no IPs, hostnames, usernames, or internal
topology details.

| Raw message (NEVER send to relay) | Sanitized message (OK for relay) |
|-----------------------------------|----------------------------------|
| `SSH login on ctrl.k3s.dev.local from 10.99.99.2 as walle` | `New SSH connection on home-1 from first-time IP` |
| `Pod authelia-9zmw9 CrashLoopBackOff in namespace authelia` | `Critical pod restart on home-1 (auth service)` |
| `CrowdSec banned 85.214.x.x on ctrl after 5 SSH attempts` | `Intrusion attempt blocked on home-1` |
| `Disk /dev/sda1 at 92% on worker.k3s.dev.local` | `Disk space warning on home-1 (node 2)` |
| `Certificate for grafana.k8s.home expires in 7 days` | `Certificate expiring soon on home-1` |
| `Kopia backup failed: SFTP connection refused to 10.99.99.1` | `Backup failed on home-1` |

**What's safe to include**: cluster name (home-1, home-2), severity, service
category (auth, storage, monitoring), action type (blocked, failed, warning).
**What's NOT safe**: IPs, FQDNs, usernames, namespace names, pod names, paths.

Sanitization is enforced at the **source** (Alertmanager templates, fail2ban
action scripts, notify_login scripts) — not at ntfy level. ntfy is a dumb
relay; the sender controls what it sees.

#### Architecture (Variant B)

```
┌─────────────────────────────────────────────┐
│ Home-1 K3S (bare-metal, trusted)            │
│                                             │
│  ntfy (Deployment, observability ns)        │  ← DETAILED alerts
│  ├── Full context: IPs, hostnames, pods     │     (internal access only)
│  ├── Ingress: ntfy.k8s.home                 │
│  └── Protected by Authelia forward auth     │
│                                             │
│  Alertmanager ──detailed──→ ntfy (local)    │
│               ──sanitized─→ ntfy (relay, via WG)
│  Gatus ──────────────────→ ntfy (local)     │
│                                             │
├─────────────────────────────────────────────┤
│ Host level (systemd, all nodes)             │
│  notify_login ──sanitized──→ ntfy (relay)   │
│              ──detailed────→ ntfy (local)   │
│  fail2ban ────sanitized────→ ntfy (relay)   │
└──────────┬──────────────────────────────────┘
           │ WireGuard mesh
           │
      ┌────┴────┐
      │  Relay  │  ntfy (K3S): sanitized messages only
      │  (VPS)  │  ├── ntfy.example.com (public)
      │         │  ├── Gatus (systemd): cluster-down detection
      │         │  └── Direct internet for push delivery
      └────┬────┘
           │
      ┌────┴──────────┐
      │ ntfy app      │ ← subscribes to relay ntfy (sanitized, instant)
      │ (phone/tablet)│    + home ntfy via VPN (detailed, when on Headscale)
      └───────────────┘
```

**Two ntfy instances, two levels of detail**:

| Instance | Location | Content | Access |
|----------|----------|---------|--------|
| ntfy (home) | Home K3S | Full detail (IPs, pods, hostnames) | VPN only (Headscale / WG) |
| ntfy (relay) | Relay K3S | Sanitized (cluster name + severity) | Public (ntfy.example.com) |

Mobile client subscribes to **both**: relay ntfy for instant push anywhere,
home ntfy for full context when on VPN. The relay notification tells you
*something happened*; the home notification tells you *exactly what*.

#### Cluster-down scenario (Variant B)

Home cluster down → home ntfy is down, but:
1. **Relay ntfy continues** — Gatus on relay detects cluster down, pushes
   sanitized alert: `home-1 cluster unreachable`
2. **Email continues** — postfix on host (systemd) sends detailed email
3. **healthchecks.io** — external dead-man's switch

**Notification channels** (3 independent layers):

| Channel | Content | Latency | Survives |
|---------|---------|---------|----------|
| ntfy relay (sanitized) | Cluster name + severity | Instant | Home cluster down |
| ntfy home (detailed) | Full context | Instant | Relay down |
| Email (postfix on host) | Full context (audit trail) | Minutes | K3S down |
| healthchecks.io | Dead-man's switch | Minutes | Home + relay down |

#### Relay without K3S (Variant A fallback)

If the relay has no K3S (minimal VPS, systemd-only), ntfy runs only on
the home cluster. Mobile clients reach it via relay SNI proxy. Cluster-down
notifications fall back to email + healthchecks.io only.

The relay variant (systemd-only vs K3S) is a per-relay decision based on
resources. Both variants use the same Ansible roles; K3S is an optional
layer controlled by inventory group membership (`k3s_control_node` or not).

---

## Integration Points

### Prometheus Alertmanager → ntfy

```yaml
# alertmanager config (in promgraf helm values)
alertmanager:
  config:
    receivers:
      - name: ntfy-critical
        webhook_configs:
          - url: http://ntfy.observability.svc/cluster-critical
            send_resolved: true
            http_config:
              basic_auth:
                username: alertmanager
                password_file: /etc/alertmanager/secrets/ntfy-password
      - name: ntfy-warning
        webhook_configs:
          - url: http://ntfy.observability.svc/cluster-warnings
    route:
      receiver: ntfy-warning
      routes:
        - match:
            severity: critical
          receiver: ntfy-critical
```

### Gatus → ntfy

```yaml
# gatus configmap
alerting:
  ntfy:
    url: http://ntfy.observability.svc
    topic: gatus-alerts
    priority: 4
    default-alert:
      enabled: true
      failure-threshold: 3
      send-on-resolved: true
```

### fail2ban → ntfy (Ansible role)

```ini
# action.d/ntfy.conf
[Definition]
actionban = curl -H "Priority: default" -H "Tags: cop" \
  -d "fail2ban: <name> banned <ip> on <hostname>" \
  http://<ntfy_url>/<ntfy_topic>
```

### notify_login → ntfy (Ansible role)

```bash
# Existing notify_login sends email. Add ntfy alongside:
curl -H "Priority: high" -H "Tags: key" \
  -d "SSH login: ${PAM_USER}@$(hostname) from ${PAM_RHOST}" \
  http://ntfy.k8s.home/ssh-alerts
```

### Monit → ntfy

```
# monitrc
set alert admin@k8s.home with reminder on 5 cycles
# Add exec action for ntfy:
if failed then exec "/usr/local/bin/ntfy-alert.sh"
```

---

## Topic Structure

```
ntfy.k8s.home/
├── cluster-critical     # Cluster down, node unreachable (urgent)
├── cluster-warnings     # Pod crashes, resource pressure (high)
├── ssh-alerts           # SSH logins on any node (high)
├── security-alerts      # CrowdSec bans, policy violations (high)
├── backup-status        # Kopia/Velero success/failure (default)
├── cert-alerts          # Certificate expiry (high)
├── gatus-alerts         # Health check failures (high)
├── deploy-status        # Kluctl deploy results (default)
└── authelia-2fa-<user>  # Future: 2FA push per user
```

### Access control (ntfy server config)

```yaml
auth-default-access: deny-all
auth-file: /var/lib/ntfy/user.db

# Service accounts (publish only)
# alertmanager → cluster-critical, cluster-warnings
# gatus → gatus-alerts
# fail2ban → security-alerts

# Admin user (subscribe to all)
# admin → *
```

---

## Client Setup

### Android
- Install [ntfy app](https://f-droid.org/packages/io.heckel.ntfy/) from F-Droid
- Add server: `https://ntfy.k8s.home` (via Headscale VPN or relay SNI proxy)
- Subscribe to topics: `cluster-critical`, `ssh-alerts`, etc.
- Enable UnifiedPush for other apps (e.g., Element Matrix client)

### iOS
- Install ntfy from App Store
- Same server + topic configuration
- Note: iOS has delivery limits (Apple Push Notification Service throttling)

### Desktop
- Web UI at `https://ntfy.k8s.home` (subscribe via browser)
- CLI: `ntfy subscribe ntfy.k8s.home/cluster-critical`

### Cross-cluster access
- Other home clusters → ntfy on home-1 via WireGuard: `http://10.99.99.1:13200` (NodePort)
- Admin on Headscale → ntfy via VPN: `http://ctrl.ts.net:13200` or `ntfy.k8s.home`
- Mobile clients → ntfy via relay SNI proxy: `https://ntfy.example.com` (TLS end-to-end)

---

## Implementation Plan (when prioritized)

| Phase | Task | Effort |
|-------|------|--------|
| 1 | Kluctl component `observability/ntfy/` (raw manifests or Helm) | Low |
| 1 | ntfy server config (auth, topics, access control) | Low |
| 1 | Ingress + forward auth (Authelia) for web UI | Low |
| 2 | Alertmanager webhook → ntfy | Low |
| 2 | Gatus webhook → ntfy | Low |
| 2 | Ansible: notify_login role adds ntfy alongside email | Low |
| 2 | Ansible: fail2ban ntfy action | Low |
| 3 | Monit ntfy integration | Low |
| 3 | Kluctl deploy status hook → ntfy | Medium |
| 3 | Cross-cluster ntfy access via WireGuard | Low |
| 4 | Authelia 2FA push (when upstream implements #7647) | Blocked |

### Dependencies

- ntfy accessible from host level (NodePort or via Ingress + DNS)
- SOPS secret for ntfy admin password and service account tokens
- Network policy: ntfy pod on relay needs internet egress (APNs/FCM for
  iOS/Android push delivery)
- Home cluster Alertmanager/Gatus need egress to relay WireGuard IP

---

## Alternatives Considered

| Alternative | Verdict |
|-------------|---------|
| Pushover | Proprietary, paid, no self-hosting |
| Gotify | Self-hosted, but no iOS app, no UnifiedPush |
| Matrix/Element | Heavy for simple alerts, but good for team chat |
| Telegram bot | Third-party dependency, privacy concern |
| Signal CLI | Complex setup, no official API |
| **ntfy** | **Open-source, self-hosted, UnifiedPush, Android+iOS, HTTP API** |
