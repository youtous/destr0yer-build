# ADR-001: Docker Swarm to K3S migration

**Status**: Done

**Context**: The cluster ran on Docker Swarm with ~30 Ansible roles. Swarm is
effectively abandoned by Docker Inc, no new features in years, the Kubernetes
ecosystem has won.

**Decision**: Fully migrate to K3S (lightweight Kubernetes).

**Consequences**:
- All Swarm code removed (available in git history)
- Services (mailserver, nextcloud, elastic, etc.) will be redeployed on K8S
- Swarm playbooks replaced by `02-k3s.yml`
- CNI moves from Docker overlay to Cilium (eBPF)
- Ingress moves from Traefik v2 to HAProxy Ingress Controller
