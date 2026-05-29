# Architecture

Decisions: [ADR-010](adr/010-multi-site-strategy.md) (multi-site),
[ADR-013](adr/013-deployment-ansible-kluctl.md) (Ansible + Kluctl)

For the full list of architecture decisions and their rationale, see
[Architecture Decision Records](adr/).

## Target topology — one K3S cluster per zone

```
           ┌──────────────────────────────────────────────────┐
           │  WireGuard PTP mesh (connects all nodes directly) │
           │                                                    │
           │  ┌──────────────────┐    ┌──────────────────┐     │
           │  │ Zone A (home)    │    │ Zone B (future)  │     │
           │  │ K3S cluster A    │    │ K3S cluster B    │     │
           │  │  ctrl + worker   │    │  independent     │     │
           │  │  full stack      │    │  garage replica  │     │
           │  └──────────────────┘    └──────────────────┘     │
           │                                                    │
           │  ┌──────────────────────────┐                     │
           │  │ Cloud relay node         │                     │
           │  │ (NOT K3S — systemd only) │                     │
           │  │ HAProxy TCP + WireGuard  │                     │
           │  │ Alloy, node-exporter     │                     │
           │  └──────────────────────────┘                     │
           └──────────────────────────────────────────────────┘
```

Each cluster is fully independent — no cross-cluster K8S networking.
Data replication (Garage S3) happens over WireGuard at the application level.

## Component stack

| Layer | Component | Purpose |
|-------|-----------|---------|
| OS | Debian 13 Trixie (kernel 6.12 LTS) | Base operating system |
| Orchestration | K3S v1.36 | Lightweight Kubernetes |
| CNI | Cilium 1.17 (eBPF, socketLB, kubeProxyReplacement) | Networking, encryption, observability |
| Ingress | HAProxy Ingress (HTTP/HTTPS/TCP, forward auth, PROXY protocol) | All L4/L7 traffic |
| TLS | cert-manager (internal CA dev, Let's Encrypt prod) | Automated certificate lifecycle |
| Identity | Authelia SSO + TOTP 2FA, OIDC for Grafana/Seafile | Authentication |
| Storage | OpenEBS hostpath + Garage S3 | Persistent volumes + object storage |
| Registry | Distribution (pull-through cache, multi-arch) | Image cache |
| VPN | WireGuard PTP mesh (always-on infra) | Encrypted inter-node links |
| Logs | Loki + Alloy (DaemonSet + systemd dual-mode) | Centralized log aggregation |
| Metrics | kube-prometheus-stack | Prometheus + Grafana + Alertmanager |
| Policy | Kyverno (digest-only images, resource limits, PSA) | Admission control |
| Runtime security | Tetragon (eBPF) | Syscall-level enforcement |
| Threat detection | CrowdSec LAPI + nftables bouncer (host) + fail2ban | Defense in depth |
| Container runtime | Podman rootless (Quadlet) | Host-level containers on relay |
| Backup | Kopia (SFTP over WG) + Velero (S3 to Garage) | Two-layer encrypted backups |
| DNS | CoreDNS (in-cluster) + dnscrypt-proxy (host) | DNS resolution |
| Mail | docker-mailserver via cloud relay (HAProxy TCP + PROXY v2) | Email |
| IoT | Home Assistant + Zigbee2MQTT/Mosquitto | Smart home (optional) |
| Files | Seafile (S3 backend on Garage, OIDC via Authelia) | File sync/share |

## Deployment boundary

```
Ansible (host-level)                Kluctl (K8S-level)
┌─────────────────────┐            ┌──────────────────────┐
│ 00-provision.yml    │            │ security/            │
│ 01-configure.yml    │            │ observability/       │
│ 02-k3s.yml          │── hands ──▶│ storage/             │
│ 03-relay.yml        │   off      │ ingress/             │
│                     │            │ authelia/            │
│ OS, packages, SSH,  │            │ mail/                │
│ firewall, WireGuard,│            │ home/                │
│ K3S + Cilium boot,  │            │ apps/                │
│ Alloy (systemd),    │            │                      │
│ CrowdSec bouncer    │            │ 14 Kluctl components │
│                     │            │ SOPS/age secrets     │
│ 67 Ansible roles    │            │                      │
└─────────────────────┘            └──────────────────────┘

just provision / configure / k3s    just deploy / diff / prune
```

## Mail architecture — cloud blind relay (ADR-006)

```
Internet (IPv4/IPv6)         Cloud relay                 Home K3S cluster
   │                            │                            │
   │── SMTP/IMAP ──▶  HAProxy TCP (layer 4)  ──▶  HAProxy Ingress ──▶ Postfix/Dovecot
   │                   send-proxy-v2              reads PROXY header
   │                   (preserves real IP)        TLS terminates here
   │                            │                            │
   │◄── SMTP out ──── nftables masquerade ◄──── WireGuard tunnel
   │                  (outbound as relay IP)
```

The relay never sees plaintext — TCP passthrough only. TLS termination
and DKIM signing happen on bare-metal. Real client IPs preserved end-to-end
via PROXY protocol v2.

## Security model

See [security.md](security.md) for the full gap analysis and network policy matrix.

```
Internet ──▶ UFW (deny all) ──▶ WireGuard (encrypted mesh)
                                       │
                         Cilium NetworkPolicy (default-deny per namespace)
                                       │
                         Kyverno (digest-only images, resource limits, PSA restricted)
                                       │
                         CrowdSec (threat detection) + Tetragon (runtime eBPF)
                                       │
                         Authelia (SSO + 2FA forward auth)
                                       │
                                   Application
```

- **Zero-trust**: all inbound blocked on bare-metal, SSH only via WireGuard mesh
- **Defense in depth**: 6 layers from UFW to application-level auth
- **Egress control**: default-deny on all pods, internet restricted to 3 components
- **Image security**: all images pinned by SHA256 digest, Kyverno enforces
- **Secrets**: Ansible Vault (hosts) + SOPS/age (K8S), zero plaintext on disk
- **Relay is untrusted**: no K3S, no secrets, no kubelet — forwards encrypted packets only
