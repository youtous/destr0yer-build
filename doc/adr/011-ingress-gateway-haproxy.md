# ADR-011: Ingress controller — Cilium Gateway API + HAProxy fallback

**Status**: Deferred — HAProxy covers all current needs (HTTP/HTTPS + TCP/mail).
Cilium Gateway API lacks TCPRoute; revisit when it stabilizes.

**Context**: The repo deploys HAProxy Ingress Controller v0.16 via Kluctl (`kluctl/ingress/haproxy/`, jcmoraisjr/haproxy-ingress chart).
With Cilium already as the CNI, we have three options. The Kubernetes Ingress API
is frozen; Gateway API is the future standard. ingress-nginx was archived in early 2026.

**Critical finding — Cilium lacks TCPRoute support**:
Cilium Gateway API does NOT support `TCPRoute` today (issue #21929, still in dev).
This means it **cannot handle raw SMTP ports (25, 587)** or other non-TLS TCP traffic.
TLS passthrough (TLSRoute via SNI) works, but plain TCP does not. A new CRD
(`CiliumGatewayL4Config`) is being designed but is not stable yet.

Also: Cilium cannot mix L4 (TCPRoute) and L7 (HTTPRoute) on the same Gateway.

**Options evaluated**:

| | Cilium Gateway API | HAProxy Ingress | Contour (Envoy) |
|---|---|---|---|
| **Proxy** | Envoy (embedded in Cilium) | HAProxy | Envoy |
| **Extra component** | None (built into CNI) | Yes (DaemonSet) | Yes (Deployment) |
| **HTTPRoute** | Yes | Yes | Yes |
| **TLSRoute/passthrough** | Yes (SNI-based) | Yes | Yes |
| **TCPRoute (SMTP, DB)** | **No** (in dev) | Yes (native) | Yes |
| **WAF** | No | ModSecurity (SPOE) | External auth service |
| **Risk** | Couples to CNI upgrades | Separate lifecycle | Separate lifecycle |

**Decision**: Hybrid approach.
- **Cilium Gateway API** for HTTP/HTTPS ingress (web services, Grafana, etc.)
  — zero extra component, eBPF performance, sufficient for L7.
- **Keep HAProxy** for L4 TCP services that Cilium can't handle yet
  (SMTP relay ports, database access, any raw TCP). HAProxy deployed via Kluctl Helm chart.
- When Cilium TCPRoute stabilizes, re-evaluate consolidating to Cilium-only.

This matches the cloud relay architecture (ADR-006): mail ports are DNAT'd at
the OS level on the relay node before they even reach K8S ingress. HAProxy on the bare-metal
K3S handles the TCP service endpoints inside the cluster.

**Action items**:
- [x] Enable `gatewayAPI.enabled: true` in Cilium Helm values
- [ ] Migrate web HTTPRoutes from HAProxy Ingress to Cilium Gateway API
- [ ] Keep HAProxy for TCP services (mail, database, legacy)
- [ ] Test on Vagrant before production
