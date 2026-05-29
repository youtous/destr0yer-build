# ADR-004: Centralized logs — Loki + Alloy (dual-mode)

**Status**: Decided

**Context**: The old Elastic stack (OpenSearch + Logstash + Beats) is archived.
The roles were already marked `@deprecated` with "replace by vector.dev".
The Trello card "OpenObserve instead of elastic" has been superseded by this decision.

**Key design constraint**: The old Swarm architecture made logging independent
of the orchestrator — beats were installed as **systemd services via apt** on
every host, with the comment _(docker not required on the host)_. Hosts in
`all_logging_elastic` got logging regardless of whether they ran Swarm.
We must preserve this pattern: logging is infrastructure, not a K3S workload.

**Decision**: Grafana Loki + Grafana Alloy (ex-Promtail), deployed in **dual mode**:
- **K3S nodes**: Alloy as DaemonSet (collects pod logs + journald)
- **Non-K3S nodes** (cloud relay, standalone hosts): Alloy as systemd service

**Justification**:
- Loki uses ~50-100 MB RAM in single-binary mode, compatible with free tier.
- Natively integrates with Grafana already in the stack (k3s_promgraf).
- LogQL is close to PromQL, no additional learning curve.
- No full-text indexing = no storage explosion. For infra logs, label search + grep
  is sufficient.
- Alloy ships as a single static binary — it works identically as a systemd
  service or as a K8S DaemonSet. Same config format, same push-to-Loki protocol.
- Alternative evaluated: VictoriaLogs (better full-text but less mature Grafana integration).

**Implementation — two roles**:
1. `alloy` (host-level role): installs Alloy as a **systemd service** via apt/binary.
   Applied to ALL hosts in the inventory. Collects journald + system logs.
   Pushes to Loki over the Headscale mesh. This is the base layer.
2. `k3s_loki` (cluster role): deploys Loki in single-binary mode via Helm.
   Configures Alloy DaemonSet for K3S-specific collection (pod logs via
   /var/log/pods, container metadata labels). Adds Loki as Grafana datasource.
3. Define retention (e.g., 7 days local, Garage S3 for archival — see ADR-012).

**Architecture**:
```
Non-K3S node (relay, standalone)      K3S nodes
┌──────────────┐                     ┌──────────────────┐
│ journald     │                     │ journald         │
│ system logs  │                     │ k3s logs         │
│      │       │                     │ pod logs         │
│      ▼       │                     │      │           │
│  Alloy       │                     │      ▼           │
│  (systemd)   │──── Headscale ────► │  Alloy           │
└──────────────┘     mesh            │  (DaemonSet)     │
                                     │      │           │
                                     │      ▼           │
                                     │  Loki            │
                                     │  (single-binary) │
                                     │      │           │
                                     │      ▼           │
                                     │  Grafana         │
                                     └──────────────────┘
```

**Inventory pattern** (mirrors the old Swarm design):
```yaml
# All hosts get logging, K3S is optional
all_logging:
  hosts:
    bare-metal-a:    # K3S server
    bare-metal-b:    # K3S agent
    cloud-relay:     # NOT in K3S, still gets logging
```
