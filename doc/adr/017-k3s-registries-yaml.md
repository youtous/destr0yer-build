# ADR-017: K3S registries.yaml configuration

**Status**: Done

**Context**: K3S supports configuring container registries via
`/etc/rancher/k3s/registries.yaml`. This file controls:
- Mirror endpoints (redirect pulls to a local cache)
- Registry authentication (credentials for private registries)
- TLS configuration (custom CA for internal registries)

The `k3s` role already has `k3s_installation_registries` in its defaults
but it is currently empty.

**Decision**: Configure `registries.yaml` on all K3S nodes via Ansible
to point at the local pull-through registry (ADR-015).

**Implementation**:
1. Configure `k3s_installation_registries` in `inventories/dev/group_vars/k3s/main.yml`:
   ```yaml
   k3s_installation_registries:
     mirrors:
       docker.io:
         endpoint:
           - "https://registry.{{ k8s_base_cluster_domain }}"
       ghcr.io:
         endpoint:
           - "https://registry.{{ k8s_base_cluster_domain }}"
       quay.io:
         endpoint:
           - "https://registry.{{ k8s_base_cluster_domain }}"
     configs:
       "registry.{{ k8s_base_cluster_domain }}":
         tls:
           ca_file: "/etc/rancher/k3s/registry-ca.crt"
   ```
2. The `k3s` role (from PyratLabs/ansible-role-k3s) handles writing this
   file to `/etc/rancher/k3s/registries.yaml` and restarting K3S
3. Deploy the registry CA certificate to all nodes via Ansible
4. The registry itself is deployed via a new `k3s_registry` role (ADR-015)

**Dependency**: ADR-015 (registry) must be deployed before configuring mirrors.
Playbook ordering: `05-storage.yml` (Garage) → `k3s_registry` → update K3S config.
