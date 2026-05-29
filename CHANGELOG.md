# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased] — k3s-v2-rework branch

### Added

- K3S cluster deployment with Cilium CNI (eBPF networking, encryption)
- Kluctl-based K8S deployments (security, storage, observability, mail, home)
- Kyverno admission policies (6 policies: image digest, resource limits, registry allowlist, security context)
- CrowdSec + Tetragon runtime security
- HAProxy Ingress Controller for TCP services (mail) + HTTPS SNI routing
- cert-manager with internal CA (dev) and Let's Encrypt DNS-01 via deSEC (prod)
- Authelia SSO/OIDC provider with 2FA
- Garage S3-compatible object storage
- Private registry pull-through cache (docker.io, ghcr.io, quay.io, registry.k8s.io)
- Velero backup to Garage S3
- Loki + Alloy centralized logging
- kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
- Gatus uptime monitoring
- testssl.sh weekly TLS scanning CronJob
- WireGuard PTP mesh for infrastructure networking
- Kopia backup over SFTP via WireGuard
- Unattended-upgrades role with staggered reboots
- Operator kubeconfig (RBAC-limited, non-admin cluster access)
- SELinux support (permissive mode)
- Namespace resource quotas and limit ranges
- Default-deny NetworkPolicy per namespace with 12 component-specific egress policies
- Authelia SSO with forward auth (dual-mode: auth_mode authelia/basic per cluster)
- Authelia admin user with SOPS-encrypted argon2id password
- Integration test playbook (99-integration-tests.yml)
- Firewall audit playbook (98-firewall-audit.yml)
- DevContainer support (Arch Linux, all tools pre-installed)
- Ansible collection youtous.destr0yer (ufw_smart_rules, users, logwatch)
- SOPS + age encryption for Kluctl secrets
- Cloud relay role (HAProxy TCP relay + WireGuard + podman Quadlet)
- CrowdSec custom SASL brute-force scenario (`custom/postfix-sasl-bf`)
- CrowdSec Authelia collection (`LePresidente/authelia`) for auth brute-force detection
- CrowdSec Online API support (`crowdsec_online_api` arg) for community blocklist + console enrollment
- CrowdSec CiliumNetworkPolicy for LAPI egress to CrowdSec CAPI (conditional on `crowdsec_online_api`)
- HAProxy relay Prometheus metrics endpoint (bind on WireGuard interface only)
- HAProxy relay IPv6 rate limiting (st_per_ip + st_per_ip6)
- K3S registry mirrors configuration for pull-through cache (docker.io, ghcr.io, quay.io, registry.k8s.io)
- Kluctl args: `crowdsec_online_api`, `crowdsec_ban_duration`, `certmanager_dns_provider`
- Kluctl args: replica counts for 7 scalable services (authelia, loki, whoami, gatus, ntfy, mta-sts, autodiscover)
- Kluctl args: cron schedules for 14 maintenance jobs (backups, reports, restarts, scans)
- Kluctl args: PVC sizes for all persistent services (parametrizable per target)
- `.github/CODEOWNERS` file for PR review assignment
- `scripts/check-versions.sh` for weekly component version audit

### Changed

- Migrated from Docker Swarm to K3S (ADR-001)
- HAProxy Ingress: migrated from haproxytech to jcmoraisjr/haproxy-ingress v0.16.1 (forward auth support)
- Target OS: Debian 13 Trixie (from Debian 12 Bookworm)
- CNI: Cilium replaces Docker overlay networking
- Ingress: HAProxy Ingress for all HTTP/HTTPS + TCP (Cilium Gateway API deferred)
- Monitoring: kube-prometheus-stack + Loki replaces Elastic stack
- Deployment: Kluctl replaces Ansible for K8S-level resources
- DNS: dnscrypt-proxy replaces plain resolv.conf
- Shell: fish + oh-my-fish replaces bash
- Repository moved from GitLab to GitHub
- CI: GitHub Actions replaces GitLab CI
- dnscrypt-proxy: migrated from manual GitHub release install to apt (Debian package)
- dnscrypt-proxy: resolver lists now auto-updated from upstream (URLs added to sources config)
- Alloy upgraded 1.8.2 → 1.16.1
- Garage upgraded v1.1.0 → v2.3.0 (admin API v2)
- Registry upgraded 2.8.3 → 3.1.1 (config path `/etc/docker/registry` → `/etc/distribution`)
- Valkey upgraded 8.1-alpine → 9.1.0-alpine
- nginx (MTA-STS) upgraded 1.27-alpine → 1.31.1-alpine
- alpine/k8s upgraded 1.32.13 → 1.36.1 (all CronJobs/init containers)
- OpenEBS StorageClass: reclaimPolicy set to Retain, added WaitForFirstConsumer + allowVolumeExpansion
- HAProxy relay: `maxconn` parametrizable, SNI rate limits independently overridable
- cert-manager: `certmanager_dns_provider` flag controls DNS-01 recursive nameservers

### Removed

- Docker Swarm code (removed, git history only)
- Elastic stack (Elasticsearch, Logstash, Kibana)
- MariaDB/PostgreSQL roles
- Caddy/Traefik v2 ingress
- Duply/GPG backup
- Debian 10/11 support
- `minisign` collection role (no longer needed after dnscrypt-proxy moved to apt)
- `node_exporter` + `monit_node_exporter` roles (replaced by Alloy)
- `k3s_registry` role (functionality covered by xanmanning.k3s `k3s_installation_registries`)
- `update_dynamic_ip` role (Cloudflare DDNS dead code, deSEC API used now)
- Scaleway reboot alias in `system_configuration` (dead code)
- Cilium Gateway API test resources (`kluctl/security/gateway/`)
- Debian Buster/Bullseye/Bookworm apt source files (Trixie only now)
- `MAINTAINERS` file (replaced by `.github/CODEOWNERS`)

## [v-1.0.0] — 2022-07-01

### Added

- Caddy v2 for HTTP(S) ingress
- Prometheus / Grafana stack for monitoring
- bat replaces ccat
- Debian 11 support

### Changed

- Traefik v2 for TCP/UDP ingress
- Docker Swarm orchestration

### Removed

- Debian 10 support

## [v-beta-0.0.1] — 2022-07-01

### Added

- CHANGELOG
- Initial Docker Swarm infrastructure
