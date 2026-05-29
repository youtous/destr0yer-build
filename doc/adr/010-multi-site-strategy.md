# ADR-010: Multi-site strategy — one K3S cluster per zone

**Status**: Decided

**Context**: Initially designed as one big K3S cluster spanning WAN. This is
wrong — etcd over WAN is a latency nightmare, Cilium cross-site adds complexity,
and a single cluster failure takes down everything.

**Decision**: One independent K3S cluster per geographic zone. The cloud relay
node is NOT part of any K3S cluster — it's a standalone forwarder.

**Target topology**:
```
┌─────────────────────────────────────────────────────────┐
│ Headscale mesh (connects everything, clusters are       │
│ independent — no cross-cluster K3S networking)           │
│                                                         │
│  ┌──────────────────┐  ┌──────────────────┐            │
│  │ Zone A (home-1)  │  │ Zone B (home-2)  │            │
│  │                  │  │                  │            │
│  │ K3S cluster A    │  │ K3S cluster B    │            │
│  │  ├── node-a1     │  │  └── node-b1     │            │
│  │  └── node-a2     │  │     (single-node) │            │
│  │                  │  │                  │            │
│  │ Workloads:       │  │ Workloads:       │            │
│  │  mail, garage,   │  │  garage (replica),│            │
│  │  monitoring,     │  │  home assistant, │            │
│  │  authelia        │  │  monitoring      │            │
│  └──────────────────┘  └──────────────────┘            │
│                                                         │
│  ┌──────────────────────────┐                           │
│  │ Cloud relay node         │                           │
│  │ (ARM64 or x86)           │                           │
│  │                          │                           │
│  │ Always (systemd):        │                           │
│  │  - WireGuard / DNAT      │                           │
│  │  - HAProxy SNI proxy     │                           │
│  │  - Gatus, Alloy          │                           │
│  │  - node-exporter         │                           │
│  │  - fail2ban              │                           │
│  │  - Headscale client      │                           │
│  │                          │                           │
│  │ Optional (if K3S):       │                           │
│  │  - ntfy (sanitized)      │                           │
│  │  - additional workloads  │                           │
│  └──────────────────────────┘                           │
└─────────────────────────────────────────────────────────┘
```

**Why multi-cluster is better**:
- No etcd spanning WAN (latency kills consensus)
- No cross-site Cilium networking (complex, fragile)
- Each cluster is independently manageable and restorable
- Relay node runs minimal K3S (SNI proxy, ntfy, Headscale) — isolated cluster, no home secrets
- A cluster failure at zone A doesn't affect zone B
- Garage handles cross-site data replication at the S3 level, not K8S level

**Core design principle**:

> If it's critical for privacy or security, it runs on bare-metal. Always.
> The cloud relay node is ONLY for public internet exposure.
> The relay forwards encrypted packets — it never terminates TLS for home services.

**Cloud relay node — lightweight K3S (ARM64, 20 GB, 3 CPU)**:

| Service | Deployment | Purpose |
|---------|------------|---------|
| WireGuard + DNAT/SNI | systemd + nftables | Forward public traffic to home clusters |
| HAProxy SNI proxy | systemd or K3S | Route HTTPS by hostname to home clusters |
| Headscale client | systemd | Tailscale node in the admin mesh |
| ntfy (optional) | K3S (if available) | Sanitized push notifications (no sensitive data) |
| Gatus | systemd | External uptime checks + anti-reclamation |
| Alloy | systemd | Ship logs to Loki on home cluster via mesh |
| node-exporter | systemd | Metrics scraped by Prometheus via mesh |
| fail2ban | systemd | Ban IPs on public ports |

The relay is provisioned with Ansible. K3S is **optional** — depends on
provider resources and topology. A minimal relay runs systemd-only (HAProxy,
WireGuard, Gatus, Alloy, fail2ban). A relay with more resources (e.g., ARM64
20 GB, 3 CPU) can run K3S for additional workloads like ntfy.

If compromised, the attacker gets a forwarder of encrypted packets. Home
cluster data stays on bare-metal. Sensitive services (Authelia, Grafana,
Loki) never run on the relay. ntfy on relay uses **sanitized messages only**
— no IPs, hostnames, or topology details are exposed.

**Cross-zone data replication**:

| Data | Replication method | Mechanism |
|------|-------------------|-----------|
| Garage S3 (files, registry) | Garage native 2-zone | S3 protocol over Headscale mesh |
| Backups | Kopia → SFTP to backup node | SFTP over Headscale mesh |
| etcd snapshots | Per-cluster, backed up by Kopia | Local + SFTP |
| Kluctl manifests | Git (GitHub) | Shared repo, per-cluster targets |
| Ansible config | Git (GitHub) | Shared repo, per-cluster inventory |

**Kluctl targets per cluster**:
```yaml
# kluctl/targets/
targets:
  zone-a:
    context: zone-a-kubeconfig
    args:
      zone: a
      cluster_domain: k8s.home-a
  zone-b:
    context: zone-b-kubeconfig
    args:
      zone: b
      cluster_domain: k8s.home-b
```

```sh
just deploy zone-a        # deploy to cluster A
just deploy zone-b        # deploy to cluster B
just diff zone-a          # preview changes on cluster A
```

**Failover if relay node disappears**:
- Mail: sending MXes retry 5 days. Time to re-provision.
- Web: DNS TTL low (5 min). Re-point if needed.
- Headscale: existing mesh tunnels persist. New registrations fail.
- All clusters continue running independently. Only public access is affected.

**Anti-reclamation**: Gatus on the relay keeps CPU >20%.

**Dead-man's switch**: External uptime ping (healthchecks.io) from the relay.
No ping = alert. This monitors the monitor.

**ARM cloud VPS specs** (free tier):
- 4 ARM vCPUs, 24 GB RAM, 200 GB NVMe, 10 TB/month egress
- Caveat: <20% CPU over 7 days may be reclaimed
- Caveat: ARM capacity hard to get in popular regions
