# ADR-027: Perplexity review findings — integrated

**Status**: Done (findings distributed across ADRs)

**Context**: External architecture review by Perplexity AI identified several
blind spots and validation points. This ADR tracks what was found and where
each finding was addressed.

**Validated (no changes needed)**:
- Cilium Gateway API stable at 2-node ~20-service scale
- OpenEBS hostpath correct for 2-node single-disk constraint
- Kluctl over Flux/ArgoCD correct for 1-2 admins (push-based)
- Split auth model (cert for K8S API, Authelia for web) is best practice
- Garage over SeaweedFS correct for lightweight geo-replication
- btrfs fine for backup node (scrub regularly)
- Kopia confirmed over Restic for our use case

**Findings integrated**:

| Finding | Severity | Action | Where |
|---------|----------|--------|-------|
| deSEC min TTL 3600s causes DNS-01 timeout | Medium | Configure cert-manager propagation timeout + recursive nameserver | ADR-024 |
| Headscale SPOF (K3S down → mesh dies → can't SSH) | **High** | Pre-auth keys on nodes + WireGuard fallback always active | ADR-005, ADR-008 |
| Enable Tailnet Lock on Headscale | Medium | Prevent rogue node additions to mesh | ADR-005 |
| etcd snapshots on cluster disk (lost if disk fails) | Medium | Kopia backs up snapshot dir, already covered | ADR-022 |
| ~~Relay kubelet can access secrets~~ | ~~High~~ | Resolved: relay is no longer a K3S agent (ADR-010 rewrite) | ADR-010 |
| ~~Consider relay as standalone~~ | ~~Medium~~ | Resolved: relay is now standalone systemd-only | ADR-010 |
| Dead-man's switch for relay monitoring | Medium | External uptime ping (healthchecks.io or equivalent) | ADR-010 |
| Kyverno: deny hostPath volume mounts | **High** | Add ClusterPolicy blocking hostPath in app namespaces | ADR-021 |
| Kyverno: image digest pinning for critical workloads | Medium | Add policy requiring `image@sha256:` for mail, auth | ADR-021 |
| Secrets management: SOPS + age for Kluctl secrets | Medium | Explicit in ADR-013 | ADR-013 |
| Cilium encryption key rotation | Medium | Document rotation process | ADR-008 |
| kluctl diff scheduled job for drift detection | Low | Add to Priority 4 | Roadmap |
| Velero for K8S-native backup (uses Kopia) | Medium | Added as ADR-026 | ADR-026 |
