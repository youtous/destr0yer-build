# ADR-016: Metrics — kube-prometheus-stack + custom alerting

**Status**: Done

**Context**: The current `k3s_promgraf` role is a custom implementation that
deploys Prometheus + Grafana via individual Helm values and custom manifests.
The community [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
chart bundles everything in a single, well-maintained chart:
- Prometheus Operator
- Prometheus
- Grafana
- Alertmanager
- node-exporter
- kube-state-metrics
- Pre-built dashboards and alert rules

k3s.rocks uses this chart (v72.5.3) and it is the de facto standard for
Kubernetes monitoring.

**Decision**: Migrate `k3s_promgraf` to wrap the `kube-prometheus-stack` chart
instead of maintaining custom manifests.

**Justification**:
- Less maintenance — community maintains dashboards, alert rules, exporters
- Includes ServiceMonitor CRDs for easy integration (Cilium, HAProxy, Loki, etc.)
- Includes node-exporter as a DaemonSet (replaces our separate host-level
  node-exporter for K3S nodes; non-K3S nodes keep the systemd service)
- Includes kube-state-metrics (cluster-level metrics we don't have today)
- Grafana datasource provisioning via ConfigMap (auto-add Loki, Prometheus)

**Implementation**:
1. Refactor `k3s_promgraf` role to use `kube-prometheus-stack` chart
2. Preserve existing custom values (security headers, whitelist IPs, domains)
3. Add Loki datasource via Grafana ConfigMap provisioning (not manual UI):
   ```yaml
   grafana:
     additionalDataSources:
       - name: Loki
         type: loki
         url: http://loki.loki.svc:3100
         access: proxy
   ```
4. Add ServiceMonitor for Cilium metrics (`prometheus.enabled: true` already
   set in Cilium values)
5. Keep host-level node-exporter (systemd) for non-K3S nodes (cloud relay),
   the chart's DaemonSet covers K3S nodes
6. Migrate existing Grafana dashboards to the chart's provisioning system

**Alerting — what is implemented**:

Alertmanager is enabled with email routing to `admin_email` via the shared
`smtp-notifier` secret. Custom PrometheusRules are deployed in
`kluctl/observability/promgraf/extras/custom-alerts.yaml`:

| Group | Alert | Threshold | Severity |
|-------|-------|-----------|----------|
| node-health | NodeHighCPUUsage | >50% for 5m | warning |
| node-health | NodeHighMemoryUsage | >80% for 5m | warning |
| node-health | NodeHighDiskUsage | >85% for 5m | warning |
| node-health | NodeDiskFillPredicted6h | linear prediction <0 in 6h | critical |
| node-health | K3SNodeNotReady | NotReady for 15m | critical |
| pod-health | PodHighCPUUsage | >0.5 cores for 5m | warning |
| pod-health | PodHighMemoryUsage | >1 GiB for 5m | warning |
| pod-health | PodCrashLooping | >=2 restarts in 15m | critical |
| storage-health | PersistentVolumeNearlyFull | >85% for 5m | warning |
| certificates | CertificateExpiringSoon | <14 days to expiry | warning |

In addition to these custom rules, the chart ships its own default alerting
rules for Kubernetes components (etcd, scheduler, kubelet, API server).

**Notification channels**:

| Channel | Status | When |
|---------|--------|------|
| Email (Alertmanager → SMTP) | Done | All alerts (grouped, 4h repeat) |
| ntfy push notifications | Planned | Future — see `doc/proposal-ntfy-push-notifications.md` |

**Alerts NOT yet covered (future work)**:

- Backup missed (Velero/Kopia no backup in 24h) — needs custom PrometheusRule or CronJob
- CrowdSec ban rate spike — needs CrowdSec metrics exporter
- WireGuard peer down — needs Alloy host-level metric or custom exporter
- Quota saturation (namespace ResourceQuota approaching limit)
