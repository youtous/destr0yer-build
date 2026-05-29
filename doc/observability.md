# Observability

Decisions: [ADR-004](adr/004-loki-alloy.md) (Loki + Alloy),
[ADR-007](adr/007-monitoring-prometheus-grafana.md) (Prometheus + Grafana),
[ADR-016](adr/016-metrics-kube-prometheus-stack.md) (kube-prometheus-stack)

## Overview

Alloy is the unified collection agent for both logs and metrics. The host Alloy
(systemd) runs on **every** server (K3S or not) and collects journald logs +
host metrics via `prometheus.exporter.unix`. The K8s Alloy DaemonSet collects
pod logs and scrapes kubelet + kube-state-metrics. Both push data to Loki
(logs) and Prometheus (metrics) respectively.

```
┌─────────────────────────────────────────────────────────────┐
│  K3S cluster (namespace: observability)                     │
│                                                             │
│  Pod logs (/var/log/pods) ──► Alloy DaemonSet ──► Loki     │
│  Kubelet /metrics + /metrics/cadvisor ──► Alloy ──►┐       │
│  kube-state-metrics ──► Alloy ──────────────────────┤       │
│                                                     ▼       │
│                                              Prometheus     │
│                                  (remote_write receiver)    │
│                                        │                    │
│       ├── Alertmanager ──► email       │                    │
│       └── Grafana ◄── Loki datasource  │                    │
│              └── Ingress: grafana.{cluster_domain}          │
│              └── OIDC via Authelia (if auth_mode=authelia)  │
│                                                             │
│  Gatus ──► synthetic checks + email alerts                  │
│  testssl CronJob ──► weekly TLS scan + email report         │
└─────────────────────────────────────────────────────────────┘
         ▲                              ▲
         │ NodePort :13100 (Loki)       │ NodePort :13090 (Prometheus)
         │                              │
┌────────┴──────────────────────────────┴─────────┐
│ Host Alloy (systemd) — universal, all servers   │
│                                                 │
│ journald ──► Loki (NodePort)                    │
│ prometheus.exporter.unix ──► Prometheus (NodePort)│
└─────────────────────────────────────────────────┘
  Ansible 01-configure.yml
  Monit: monit_alloy
```

## Components

| Component | Method | Path | Purpose |
|-----------|--------|------|---------|
| Loki | Kluctl Helm | `kluctl/observability/loki/` | Log aggregation (SingleBinary, 10Gi PVC) |
| Alloy (K8s) | Kluctl Helm | `kluctl/observability/alloy/` | DaemonSet: pod logs → Loki, kubelet + kube-state-metrics → Prometheus |
| Alloy (host) | Ansible role | `roles/alloy/` | systemd: journald → Loki, `prometheus.exporter.unix` → Prometheus |
| promgraf | Kluctl Helm | `kluctl/observability/promgraf/` | kube-prometheus-stack (Prometheus + Grafana + Alertmanager) |
| Gatus | Kluctl raw | `kluctl/observability/gatus/` | Synthetic uptime checks (K8s API, CoreDNS, registry, Cilium) |
| testssl | Kluctl raw CronJob | `kluctl/observability/testssl/` | Weekly TLS audit, email report |

Deploy order: `promgraf` → `loki` → `alloy` → `gatus` → `testssl`
(defined in `kluctl/observability/deployment.yaml`).

## Host Alloy — universal agent

The host Alloy config (`roles/alloy/templates/config.alloy.j2`) is the same on
every server. It has **no Kubernetes dependency** — it works on K3S nodes,
relay, backup node, or any future host.

Two functions:
- **Logs**: `loki.source.journal` → push to Loki via NodePort (:13100)
- **Metrics**: `prometheus.exporter.unix` (replaces node_exporter) → scrape →
  `prometheus.remote_write` to Prometheus via NodePort (:13090)

Labels: `cluster` (env), `node` (hostname), `job = "node"` for metrics,
`job = "journal"` for logs.

Ansible vars (`roles/alloy/defaults/main.yml`):
- `alloy_loki_endpoint` — Loki push URL
- `alloy_prometheus_endpoint` — Prometheus remote_write URL (empty to disable)

## K8s Alloy DaemonSet — cluster-only

Handles everything that requires K8s API access:

- **Pod logs**: CRI file discovery → Loki (in-cluster)
- **Kubelet metrics**: `discovery.kubernetes` role=node, scrapes `/metrics` and
  `/metrics/cadvisor` via API server proxy (no standalone cAdvisor needed)
- **kube-state-metrics**: scraped from the kube-prometheus-stack deployment
- All metrics pushed via `prometheus.remote_write` to in-cluster Prometheus

RBAC: `ClusterRole` `alloy-kubelet-metrics` with access to `nodes/metrics`,
`nodes/proxy`, and non-resource URLs (`/metrics`, `/metrics/cadvisor`).

## Prometheus + Grafana

**Prometheus**: 15-day retention, 50Gi PVC on `openebs-hostpath`.
`enableRemoteWriteReceiver: true` to accept pushes from both Alloy instances.
Exposed via NodePort :13090 for host Alloy.

**Grafana**: Ingress at `grafana.{cluster_domain}`. Loki and Prometheus as
datasources. CrowdSec dashboard included.

**Authentication** (controlled by `args.auth_mode`):
- `authelia`: OIDC via Authelia (auto role mapping: `admins` group → Admin)
- `basic`/default: admin password from SOPS only

**Custom alerts** (PrometheusRule `custom-alerts.yaml`):
- Node: CPU >50%, memory >80%, disk >85%, fill predicted 6h, K3S NotReady
- Pod: CPU >0.5 core, memory >1GiB, crash looping (2+ restarts/15m)
- Storage: PVC >85% full
- Certificates: cert-manager cert expiring <14 days

## Loki

SingleBinary mode, 1 replica, filesystem storage (TSDB v13 schema).
Retention: `args.loki_retention_days` (default 7 days), compactor-based.
Exposed via NodePort :13100 for host Alloy. Auth disabled.

## Gatus and testssl

**Gatus**: checks K8s API, CoreDNS, registry cache, Cilium envoy every 60s.
Alerts via cluster SMTP.

**testssl**: weekly CronJob scanning `grafana`, `auth` endpoints (configurable via `testssl_hosts`).
Emails report with `[NOT OK]` in subject on failure.

## Operations

```sh
just deploy-only observability/promgraf  # redeploy Prometheus+Grafana
just deploy-only observability/loki      # redeploy Loki
just deploy-only observability/alloy     # redeploy K8s Alloy

just configure                           # redeploy all host roles including Alloy
```

Monit watches the host Alloy service: `roles/monit_alloy/` (restart on failure,
alert after 5 restarts).
