# Architecture Decision Records

This directory tracks all architecture and refactoring decisions for the
destr0yer-build project (K3S Kubernetes cluster).

ADRs are grouped by implementation phase. Within each phase, order roughly
reflects dependency (earlier ADRs are prerequisites for later ones).

Lifecycle: **ADR** (decision) → **implementation** (roles/kluctl) → **Doc** (how it works)

## Phase 0 — Foundation

| # | Decision | Status | Doc |
|---|----------|--------|-----|
| [001](001-k3s-migration.md) | Docker Swarm to K3S migration | ✅ Done | -- |
| [002](002-debian-trixie.md) | Debian Bookworm (12) to Trixie (13) upgrade | ✅ Done | -- |
| [009](009-ci-github-actions.md) | CI/CD — GitHub Actions | ✅ Done | [testing](../testing.md) |
| [014](014-master-branch-cleanup.md) | Master branch cleanup | ✅ Done | -- |
| [028](028-podman-rootless.md) | Container runtime — Podman rootless (replaces Docker) | ✅ Done | -- |
| [030](030-systemd-timers.md) | Systemd timers over cron | ✅ Done | -- |

## Phase 1 — Core infrastructure

| # | Decision | Status | Doc |
|---|----------|--------|-----|
| [003](003-openebs-hostpath.md) | K3S storage — OpenEBS hostpath | ✅ Done | [storage](../storage.md) |
| [005](005-vpn-wireguard-headscale.md) | VPN mesh — Two-tier design (WireGuard PTP + Headscale deferred) | ✅ Done | [networking](../networking.md) |
| [008](008-network-zero-trust.md) | Network security — Zero-trust with WireGuard PTP + Cilium | ✅ Done | [security](../security.md) |
| [010](010-multi-site-strategy.md) | Multi-site strategy — one K3S cluster per zone | ✅ Done | [architecture](../architecture.md) |
| [013](013-deployment-ansible-kluctl.md) | Deployment strategy — Ansible (hosts) + Kluctl (K8S) | ✅ Done | [architecture](../architecture.md) |
| [017](017-k3s-registries-yaml.md) | K3S registries.yaml configuration | ✅ Done | [registry](../registry.md) |
| [020](020-namespace-templates.md) | Namespace templates — security by default | ✅ Done | [security](../security.md) |

## Phase 2 — Security and access control

| # | Decision | Status | Doc |
|---|----------|--------|-----|
| [018](018-authelia-sso.md) | Identity and access management — Authelia SSO | ✅ Done | [authelia](../authelia.md) |
| [021](021-kyverno-policy-engine.md) | Kyverno — policy engine for admission control | ✅ Done | [security](../security.md) |
| [025](025-k8s-api-auth.md) | K8S API authentication — certificate via SSH, Authelia for web services | ✅ Done | [security](../security.md) |

## Phase 3 — Observability

| # | Decision | Status | Doc |
|---|----------|--------|-----|
| [004](004-loki-alloy.md) | Centralized logs — Loki + Alloy (dual-mode) | ✅ Done | [observability](../observability.md) |
| [007](007-monitoring-prometheus-grafana.md) | Monitoring — Prometheus + Grafana + Loki | ✅ Done | [observability](../observability.md) |
| [016](016-metrics-kube-prometheus-stack.md) | Metrics — kube-prometheus-stack + custom alerting | ✅ Done | [observability](../observability.md) |

## Phase 4 — Storage, backup and DR

| # | Decision | Status | Doc |
|---|----------|--------|-----|
| [012](012-object-storage-garage.md) | Object storage — Garage (S3-compatible) | ✅ Done (single-node) | [storage](../storage.md) |
| [015](015-private-registry.md) | Private registry with pull-through cache | ✅ Done | [registry](../registry.md) |
| [022](022-backup-sftp-btrfs.md) | Backup strategy — SFTP + btrfs + K3S etcd snapshots | ✅ Done | [storage](../storage.md) |
| [023](023-disaster-recovery.md) | Disaster recovery plan | 📋 Decided | -- |
| [026](026-velero-backup.md) | Velero — K8S-native backup with Kopia backend | ✅ Done | [storage](../storage.md) |
| [035](035-usb-storage.md) | USB disk storage for local K3S workloads | ✅ Done | [usb-storage](../usb-storage.md) |

## Phase 5 — Ingress, certificates and applications

| # | Decision | Status | Doc |
|---|----------|--------|-----|
| [011](011-ingress-gateway-haproxy.md) | Ingress controller — Cilium Gateway API + HAProxy fallback | ⏸️ Deferred | [networking](../networking.md) |
| [024](024-cert-manager.md) | Certificate management — centralized cert-manager + split DNS | ✅ Done (dev), ⏳ Let's Encrypt (prod) | [certificates](../certificates.md) |
| [019](019-home-assistant.md) | Home Assistant — IoT hub for home clusters | ✅ Done | [home-automation](../home-automation.md) |
| [031](031-mqtt-zigbee2mqtt.md) | MQTT + Zigbee2MQTT for Home Automation | ✅ Done (USB dongle TBD) | [home-automation](../home-automation.md) |
| [032](032-seafile.md) | Seafile for file sync/share (replaces Nextcloud) | ✅ Done (encryption TBD) | -- |

## Phase 6 — Mail and cloud relay

| # | Decision | Status | Doc |
|---|----------|--------|-----|
| [006](006-mail-cloud-relay.md) | Mail architecture — cloud blind relay | ✅ Done | -- |
| [033](033-mail-dual-cluster-backup-mx.md) | Mail architecture — dual-cluster with backup MX and whitehole NAT | 📋 Proposed | -- |
| [034](034-dms-v10-to-v15-migration.md) | DMS v10 to v15 mail migration — standalone Podman or K8S | ✅ Done (role), ⏳ Prod migration | -- |

## Phase 7 — Future

| # | Decision | Status | Doc |
|---|----------|--------|-----|
| [036](036-ipv6-dual-stack.md) | IPv6 dual-stack for K3S and cloud relay | 📋 Proposed | -- |

## Phase 8 — Operational hardening

| # | Decision | Status | Doc |
|---|----------|--------|-----|
| [037](037-kluctl-force-apply.md) | Kluctl force-apply by default — prevent silent SSA field ownership loss | ✅ Done | [architecture](../architecture.md) |

## Backlog

| # | Decision | Status | Doc |
|---|----------|--------|-----|
| [029](029-additional-services.md) | Additional services (future) | ✅ Done | -- |

## Reference

| # | Decision | Status | Doc |
|---|----------|--------|-----|
| [027](027-perplexity-review.md) | Perplexity review findings — integrated | ✅ Done | -- |
