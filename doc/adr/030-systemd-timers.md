# ADR-030: Systemd timers over cron

**Status**: Done

**Context**: The project historically used `ansible.builtin.cron` for scheduled
tasks (backups, IP change notifications, DNS updates). Cron has several
limitations in a modern systemd-based Debian 13 environment:

- **No catch-up after downtime**: If the machine is powered off when a cron job
  was scheduled, the job is silently skipped. For backups, this means missed
  backup windows with no alert.
- **No native logging**: Cron output goes to mail or `/dev/null`. Debugging
  requires separate log files and logrotate config.
- **No dependency management**: Cron cannot express "run after network is up"
  or "run after this mount is available".
- **No jitter**: All nodes with the same schedule hit the backup server
  simultaneously.
- **Duplicate daemon**: systemd-based systems already have a timer subsystem.
  Running crond alongside is an extra process to monitor and secure.

**Decision**: Use systemd timers for all scheduled tasks. Migrate existing cron
jobs to `.timer` + `.service` unit pairs deployed via Ansible templates.

**Key benefits**:
- `Persistent=true` — if the machine was off at the scheduled time, the job
  runs at the next boot. Critical for backups and monitoring.
- `RandomizedDelaySec` — spreads execution across nodes to avoid thundering
  herd on shared resources (backup SFTP server, DNS API).
- Native journald logging — `journalctl -u <service>` shows full history,
  no separate logrotate needed.
- Dependency ordering — `After=network-online.target`, `After=local-fs.target`.
- `systemctl list-timers` — single command to see all scheduled jobs, next run,
  and last run across the system.
- Monit can check `systemctl is-active <timer>` for alerting.

**Migration scope**:

| Role | Old (cron) | New (systemd timer) |
|------|-----------|-------------------|
| `kopia` | N/A (new role) | `kopia-snapshot.timer`, `kopia-verify.timer` |
| `backup_storage` | rsync cron | `btrfs-snapshot.timer`, `btrfs-scrub.timer`, `btrfs-cold-send.timer` |
| `notify_ip_change` | `cron: */5 * * * *` | `notify-ip-change.timer` |
| `update_dynamic_ip` | `cron: */5 * * * *` | Removed (Cloudflare DDNS dead code, deSEC API used now) |
| `logwatch` | External role uses cron | Keep cron (external `youtous.logwatch` role dependency) |
| `monit` | Monitors crond | Updated: monitors remaining cron only if logwatch is present |

**Logwatch exception**: The `youtous.logwatch` external role directly creates a
cron entry. Migrating it requires forking the role. Cron stays installed as long
as logwatch needs it, but no new cron jobs should be added. When logwatch is
eventually replaced (e.g., by Loki alerting), cron can be fully removed.

**Template pattern** for new timers:
```ini
# {{ ansible_managed }}
[Unit]
Description=<what it does>

[Timer]
OnCalendar=<systemd calendar expression>
Persistent=true
RandomizedDelaySec=<seconds>

[Install]
WantedBy=timers.target
```
