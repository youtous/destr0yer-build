# ADR-028: Container runtime — Podman rootless (replaces Docker)

**Status**: Done

**Context**: Docker was dropped from the stack (ADR, T6). K3S uses containerd
internally. But some host-level tasks need a container runtime:
- `monitor_testssl` runs testssl.sh in a container
- Future: Quadlet (systemd-native container management) for host-level services
  that don't belong in K3S (e.g., standalone services on relay/backup nodes)

**Decision**: Podman rootless as the host-level container runtime.

**Why Podman over nerdctl**:
- nerdctl shares K3S's containerd — debug containers run in the same namespace
  as cluster workloads (security risk)
- Podman is fully isolated, rootless by default, daemonless
- Quadlet integration (systemd units for containers) — native in Podman 4+
- Available in Debian 13 repos (`apt install podman`)

**Implementation**:
- Add `podman` to `system_packages` role (installed on all nodes)
- Configure rootless mode (subuid/subgid) via Ansible
- Update `monitor_testssl` to use `podman run` instead of `docker run`
- Quadlet for standalone containers on non-K3S nodes:
  - `cloud_relay`: HAProxy via rootless Podman with `Network=pasta` (user `haproxy-relay`, UID 5100)
  - `podman_mailserver`: DMS + Nginx + Autodiscover via rootless Podman with `Network=pasta` (user `mail-dms`, UID 5200)

**Rootless networking — pasta**:
Both `cloud_relay` and `podman_mailserver` use `Network=pasta` (passthrough
to user namespace) instead of `Network=host` (which is unavailable in rootless
Podman due to user namespace isolation). Pasta preserves source IP addresses
for TCP connections, which is required for fail2ban (DMS), rate limiting (HAProxy),
and PROXY protocol. Each role uses `PublishPort` directives in the Quadlet unit
to expose specific ports. Privileged port binding requires
`sysctl_net_ipv4_ip_unprivileged_port_start` set to the lowest needed port (e.g. 25).

**UID mapping**:
Each role creates a dedicated system user with non-overlapping subuid/subgid ranges:
- `haproxy-relay` (UID 5100): subuid 200000:65536
- `mail-dms` (UID 5200): subuid 300000:65536

For migrated data (e.g. DMS v10 → v15), `podman unshare chown` remaps host UIDs
into the container's user namespace so internal processes see correct ownership.
