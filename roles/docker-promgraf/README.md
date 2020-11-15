# Docker Prometheus-Grafana stack

This stack used for real-time monitoring contains:
- **prometheus** as a time-based database
- **grafana** for visualization
- **alertmanager** for alerting

## Getting started

Register domains:

- `promgraf_base_domain`: `rlt.{{ hostname }}`
- `prometheus_domain`: `prom.{{ promgraf_base_domain }}`
- `grafana_domain`: `graph.{{ promgraf_base_domain }}`
- `alertmanager_domain`: `alerts.{{ promgraf_base_domain }}`