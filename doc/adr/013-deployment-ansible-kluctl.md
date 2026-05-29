# ADR-013: Deployment strategy — Ansible (hosts) + Kluctl (K8S)

**Status**: Done

**Context**: In the Swarm era, each service was a role that templated a
`docker-compose.*.j2.yml`, deployed via `docker stack deploy`, and managed by
its own Ansible role. This was simple but tightly coupled to Swarm.

For K3S, Ansible's `kubernetes.core` module works but has fundamental gaps:
- No diff before apply (can't preview changes)
- No orphan pruning (renamed resources leave ghosts)
- No drift detection (cluster state diverges silently)

**Decision**: Split the deployment boundary — Ansible for hosts, Kluctl for K8S.

**Why Kluctl**:
- Uses **Jinja2** for templating — same language as Ansible, zero learning curve
- `kluctl diff` shows exactly what will change before applying
- `kluctl prune` removes orphaned resources
- Handles Helm charts natively (renders + deploys)
- ~30 MB CLI, optional in-cluster GitOps controller (add later if needed)
- Lighter than ArgoCD (~500 MB), more capable than raw Helm

**Boundary**:
```
Ansible (host-level)              Kluctl (K8S-level)
┌─────────────────────┐          ┌──────────────────────┐
│ 00-provision.yml    │          │ kluctl/              │
│ 01-configure.yml    │          │   .kluctl.yaml       │
│ 02-k3s.yml          │─ hands ─►│   targets/           │
│                     │  off     │     dev.yaml         │
│ OS, packages, SSH,  │          │     prod.yaml        │
│ K3S install, Cilium │          │   observability/     │
│ boot, WireGuard,    │          │   security/          │
│ fail2ban, Alloy     │          │   storage/           │
│ (systemd),          │          │   mail/              │
│ node-exporter       │          │   home/ (optional)   │
└─────────────────────┘          └──────────────────────┘

just provision  →  Ansible   just deploy  →  Kluctl
just configure  →  Ansible   just diff    →  Kluctl
just k3s        →  Ansible   just prune   →  Kluctl
```

**Ansible stays for** (playbooks 00-01-02):
- OS provisioning, packages, users, SSH hardening
- K3S binary install + cluster join
- Cilium bootstrap (must exist before any K8S tool runs)
- Host-level services: Alloy (systemd), node-exporter, fail2ban, WireGuard,
  dnscrypt-proxy — these run on every host regardless of K3S (see ADR-004)
- K3S `registries.yaml` (ADR-017, host-level file)

**Kluctl takes over for** (everything inside K8S):
- Helm charts (Loki, Prometheus, cert-manager, OpenEBS, Garage, Authelia, etc.)
- K8S manifests (NetworkPolicies, namespace templates, custom resources)
- Namespace lifecycle (default security policies via ADR-020)

**Kluctl project structure** (lives in the repo alongside Ansible):
```
kluctl/
  .kluctl.yaml                   # project config
  targets/
    dev.yaml                     # dev cluster vars
    prod.yaml                    # prod cluster vars
  deployment.yaml                # root: lists all components in order
  observability/
    deployment.yaml
    loki/
      helm-chart.yaml            # chart ref + version
      helm-values.yaml.j2        # Jinja2 values (same syntax as Ansible!)
    promgraf/
      helm-chart.yaml
      helm-values.yaml.j2
  security/
    deployment.yaml
    authelia/
    crowdsec/
    kyverno/
    namespace-defaults/          # default NetworkPolicy, LimitRange, ResourceQuota
  storage/
    deployment.yaml
    openebs/
    garage/
    registry/
  mail/
    deployment.yaml
    mailserver/
    parsedmarc/
  home/                          # optional, only for home clusters
    deployment.yaml
    homeassistant/
```

**Workflow**:
```sh
kluctl diff -t dev          # preview what would change
kluctl deploy -t dev        # apply all components
kluctl deploy -t dev -I storage/  # deploy only storage components
kluctl prune -t dev         # remove orphaned resources
```

**Shared variables**: Kluctl targets can reference the same YAML var files
from `inventories/dev/group_vars/` via Jinja2, or maintain their own
`targets/dev.yaml`. No coupling at the tool level — the justfile is the
unified interface.

**Secrets in Kluctl** (Perplexity finding): Use **SOPS + age** for encrypting
secrets in the Kluctl deployment files. Kluctl has native SOPS integration —
secrets are encrypted in git, decrypted at deploy time. The age key stays
on the admin's machine (or in Ansible Vault). This avoids plaintext secrets
in ConfigMaps or unencrypted files.

**Migration path**: Former Ansible K3S roles (`k3s_certmanager`,
`k3s_haproxy`, `k3s_promgraf`) have been migrated to Kluctl and deleted.
Cilium bootstrap stays in Ansible (`k3s_cilium` role, must exist before
Kluctl can reach the API server).
