# ADR-007: Monitoring — Prometheus + Grafana + Loki

**Status**: Decided

**Context**: The role `k3s_promgraf` already deploys Prometheus + Grafana in the
K3S cluster. Logs are added via Loki (see ADR-004).

**Target monitoring stack** (dual-mode, K3S-independent base layer):
```
                      K3S cluster
┌───────────────────────────────────────────────┐
│                   Grafana                      │
│  ┌──────────┐  ┌──────┐  ┌───────────────┐   │
│  │Prometheus │  │ Loki │  │ (Tempo,       │   │
│  │ metrics   │  │ logs │  │  future)      │   │
│  └────▲─────┘  └──▲───┘  └───────────────┘   │
│       │            │                           │
│  node-exporter  Alloy (DaemonSet)              │
│  kube-state     pod logs + journald            │
│  cadvisor                                      │
└───────────────────────▲───────────────────────┘
                        │ Headscale mesh
                        │
            ┌───────────┴───────────┐
            │  Non-K3S nodes        │
            │  (relay, standalone)  │
            │                       │
            │  Alloy (systemd)      │
            │  node-exporter        │
            │  journald → Loki      │
            └───────────────────────┘
```

All nodes get observability. K3S is optional. Mirrors the old Swarm design
where beats were systemd services on every host in `all_logging_elastic`.

**Related Trello items**:
- "Gatus as part of the main stack" — deploy Gatus for uptime monitoring
  and status page. Lightweight Go binary, fits the K3S stack well.
- "InfluxDB (TICK) + Grafana => IoT" — future consideration for IoT time-series.
  Prometheus may be sufficient; evaluate when IoT workloads materialize.
