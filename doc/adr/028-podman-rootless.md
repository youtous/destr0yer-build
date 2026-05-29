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
- Future: use Quadlet for standalone containers on non-K3S nodes (relay, backup)
