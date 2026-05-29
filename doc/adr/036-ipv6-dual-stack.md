# ADR-036: IPv6 dual-stack for K3S and cloud relay

**Status**: Proposed
**Date**: 2026-05-27
**Supersedes**: None
**Related**: ADR-005 (WireGuard), ADR-006 (mail cloud relay), ADR-010 (cloud relay provisioning)

## Context

The infrastructure currently runs IPv4-only at the Kubernetes level:
- `cluster-cidr: "10.42.0.0/16"` (no IPv6 pod CIDR)
- Cilium IPAM: IPv4 pool only
- Cloud relay: `relay_haproxy_ipv6: false`
- WG PostUp: all IPv6 TCP traffic dropped on INPUT

IPv6 addresses exist on nodes (ULA on WG, link-local on interfaces) but are
unused by K3S. The relay is designed for dual-stack (`bind [::]:port v6only`
templates exist) but not activated.

Adding IPv6 is needed for:
- Mail deliverability (some providers prefer IPv6, reduces NAT issues)
- Future-proofing (IPv4 scarcity, cloud providers increasingly IPv6-native)
- Compliance with RFC 6724 (address selection) — dual-stack is the standard

## Critical constraint: in-place migration from IPv4-only

**K3S official documentation states**:
> "Dual-stack networking must be configured when the cluster is first created.
> It cannot be enabled on an existing cluster once it has been started as
> IPv4-only."

**Root cause** (upstream Kubernetes limitation): the IPAM controller assigns Pod
CIDRs (`node.spec.podCIDRs`) to nodes only when they first join the cluster.
There is no built-in logic to assign a new IPv6 CIDR to existing nodes if the
cluster is later reconfigured. Kubernetes 1.33 resolved in-place conversion for
Service CIDRs (PR #131263), but Pod CIDR migration remains unsupported.

### Cilium bypass (applicable to our stack)

Our cluster uses **Cilium in `cluster-pool` IPAM mode**. In this mode, Cilium
manages pod IP allocation independently from the Kubernetes IPAM controller —
it does NOT rely on `node.spec.podCIDRs`. Adding `clusterPoolIPv6PodCIDRList`
to Cilium's Helm values and restarting Cilium agents is sufficient for new pods
to receive dual-stack addresses.

This is confirmed by community reports (k3s-io/k3s#11280):
> "I hacked it in by modifying the IP ranges in kine/etcd [...] Everything has
> been working without a hitch, though I'm using Cilium and not the built-in CNI."

### Migration strategy for our cluster

1. **Update K3S server flags**: add IPv6 to `cluster-cidr` and `service-cidr`.
   This tells the apiserver to accept dual-stack Services. Restart K3S server.
2. **Update Cilium Helm values**: add `clusterPoolIPv6PodCIDRList` and
   `ipv6.enabled: true`. Cilium will start allocating IPv6 to new pods.
3. **Existing pods keep IPv4 only** — they must be restarted (rolling restart of
   Deployments) to receive a dual-stack address.
4. **Nodes do NOT need to be deleted/rejoined** — Cilium's cluster-pool IPAM
   bypasses the node.spec.podCIDRs limitation.
5. **Verify**: `kubectl get nodes -o jsonpath='{.items[*].spec.podCIDRs}'` may
   still show IPv4-only. This is cosmetic — Cilium allocates from its own pools.

### Risks of in-place migration

- **Untested by K3S team** — not a supported path. Must test thoroughly in dev.
- **kube-controller-manager** may log warnings about missing IPv6 node CIDRs.
  These are harmless with Cilium IPAM but noisy.
- **Services created before migration** default to `ipFamilyPolicy: SingleStack`.
  They must be recreated (not just updated) to become dual-stack.
- **If migration fails**: worst case, remove IPv6 flags and restart. Existing
  IPv4 connectivity is not affected by adding IPv6 CIDRs.

## Decision

Implement IPv6 dual-stack in phases, with mail IPv6 gated on PTR/SPF readiness.
Use Cilium's `cluster-pool` IPAM to bypass K3S's in-place migration limitation.

## Architecture

### Inbound (Internet → Relay → K3S)

```
Client (IPv4 or IPv6)
    │
Relay HAProxy (bind :port + [::]:port v6only)
    │ TCP passthrough + PROXY protocol v2 (carries original IP family)
    │
WireGuard tunnel (IPv4 10.99.99.x — tunnel transport is always IPv4)
    │
K3S HAProxy Ingress (hostNetwork, listens on [::])
    │ PROXY protocol preserves client IPv6 even though tunnel is IPv4
    │
Postfix / Dovecot (sees real client IPv6 from PROXY header)
```

Key insight: the WireGuard tunnel itself can stay IPv4-only (10.99.99.0/24).
PROXY protocol v2 transports the original client address regardless of the
tunnel's IP family. A client connecting via IPv6 to the relay will have its
IPv6 preserved end-to-end in the PROXY header.

### Outbound (Postfix → Internet)

```
Postfix pod (fd42::x or 10.42.x.x)
    │ SMTP to remote MTA
    │
Cilium routing → K3S node
    │
WireGuard tunnel → Relay (10.99.99.1)
    │
NAT masquerade (POSTROUTING on relay)
├── IPv4: iptables MASQUERADE → public IPv4 of relay
└── IPv6: ip6tables MASQUERADE → public IPv6 of relay
    │
Internet (remote MTA sees relay's public IP)
```

Outbound mail uses masquerade (option A) rather than direct pod-to-internet
routing because:
1. Single IP in SPF record (one /128 for IPv6, one /32 for IPv4)
2. PTR record maps to relay's public IPs (not pod IPs)
3. No need to route a public IPv6 subnet into the cluster
4. Same pattern for both address families — simpler operations

The relay's `before.rules` (UFW) adds:
```
-A POSTROUTING -s 10.99.99.0/24 -o eth0 -j MASQUERADE   # IPv4 (existing)
-A POSTROUTING -s fdc9:281f:4d7:9ee9::/64 -o eth0 -j MASQUERADE  # IPv6 (new)
```

### Outbound SMTP routing (K3S → Relay → Internet)

**Problem**: without explicit routing, outbound mail from the Postfix pod exits
via the K3S node's default gateway — bypassing the relay entirely. The remote
MTA sees the K3S node's IP, not the relay's. PTR/SPF won't match.

**Solution**: policy routing on the K3S node forces outbound SMTP (dport 25)
through the WireGuard tunnel to the relay, where masquerade rewrites the
source to the relay's public IP.

```
Postfix pod (10.42.x.x)
    │ dst=gmail-smtp-in:25
    │
Cilium SNAT → node IP (192.168.56.10 or public IP)
    │
iptables MARK (dport 25) → fwmark 0x100
    │
ip rule fwmark 0x100 → table 100
    │
table 100: default via 10.99.99.1 dev wg0  (relay WG IP)
    │
WireGuard tunnel → Relay
    │
FORWARD + MASQUERADE → Internet (relay public IP)
```

Implementation on the K3S node (PostUp or systemd unit):

```bash
# Mark outbound SMTP packets (after Cilium SNAT, in PREROUTING won't work)
iptables -t mangle -A OUTPUT -p tcp --dport 25 -j MARK --set-mark 0x100
# For pods (traffic comes from FORWARD after Cilium masquerades):
iptables -t mangle -A FORWARD -p tcp --dport 25 -o eth+ -j MARK --set-mark 0x100

# Route marked traffic via WG to relay
ip rule add fwmark 0x100 table 100
ip route add default via 10.99.99.1 dev wg0 table 100
```

**Interaction with Cilium eBPF**: Cilium processes pod traffic at TC (traffic
control) level. For pods with `hostNetwork: false`, Cilium performs SNAT before
packets reach iptables mangle/FORWARD. The marking in FORWARD catches the
packet AFTER Cilium has rewritten the source but BEFORE the kernel makes the
routing decision. The `ip rule` then redirects to the WG tunnel.

**Caveats**:
- Verify with `tcpdump -i wg0 port 25` that outbound SMTP actually enters the tunnel
- If Cilium's `bpf_lxc` program makes the routing decision before iptables,
  this approach won't work — fall back to `DEFAULT_RELAY_HOST` in Postfix config
- The mangle FORWARD rule needs `-o` matching the default outbound interface
  (not wg0, to avoid loops)
- IPv6 equivalent: same rules with `ip6tables -t mangle` + `ip -6 rule` + `ip -6 route`

**Relay side**: no changes needed — the existing FORWARD + MASQUERADE rules
already handle traffic arriving from the WG subnet. The `wg-filter-cluster`
chain on the relay filters INPUT only (not FORWARD), so forwarded SMTP passes.

**Fallback (simpler, if policy routing conflicts with Cilium)**:

Set `DEFAULT_RELAY_HOST=[10.99.99.1]:25` in docker-mailserver env vars.
Postfix then connects to the relay's WG IP directly. Traffic flows through
Cilium → node → WG → relay → masquerade → internet. No policy routing needed.
Downside: relay must accept port 25 from the cluster on its `wg-filter-cluster`
INPUT chain (add an ACCEPT rule for tcp/25 from the K3S WG IP).

## Implementation phases

### Phase 1: K3S dual-stack (internal only, no external impact)

- Add IPv6 pod CIDR: `cluster-cidr: "10.42.0.0/16,fd42::/48"`
- Add IPv6 service CIDR: `service-cidr: "10.43.0.0/16,fd43::/112"`
- Set `node-ip` to dual-stack on all nodes (server + agent)
- Cilium: add `clusterPoolIPv6PodCIDRList`, enable `ipv6.enabled: true`
- Cilium: `enableIPv6Masquerade: true` (ULA pods, not publicly routable)
- Kluctl args: add `pod_cidr_v6`, `service_cidr_v6`
- Update `allowlist-source-range`, `trustedNetworks` to include IPv6 CIDRs
- NetworkPolicies: audit and add IPv6 CIDRs where needed

### Phase 2: WireGuard IPv6 filter update

- Replace `ip6tables DROP all` with port-specific rules (same as IPv4):
  ACCEPT tcp dports 25,465,587,993,443,80 + ICMP + ESTABLISHED
- Test from worker VM via WG IPv6 address

### Phase 3: Relay dual-stack (external-facing)

Prerequisites (must ALL be met before activation):
- [ ] Relay has a public IPv6 address from the VPS provider
- [ ] PTR record (rDNS) configured for the IPv6 address
- [ ] SPF record updated with `ip6:<relay-ipv6>/128`
- [ ] AAAA record published for `mail.domain.com`
- [ ] Masquerade IPv6 added to relay's `before.rules`

Activation:
- Set `relay_haproxy_ipv6: true`
- Update `mail_relay_wg_ip` logic if relay arrives via IPv6 on the WG

### Phase 4: Validation and monitoring

- Send test emails via IPv6 (force with `smtp_bind_address6` in Postfix)
- Verify deliverability: mail-tester.com, Gmail, Microsoft
- Add monitoring alerts for IPv6 connectivity loss
- Verify CrowdSec/fail2ban handle IPv6 source IPs correctly

## Best practices for IPv6 mail

1. **PTR mandatory** — without reverse DNS for the IPv6 address, Gmail/Microsoft
   reject or spam-classify outbound mail. Do NOT enable IPv6 outbound without PTR.

2. **SPF: single /128** — list exactly one IPv6 address in SPF (`ip6:2001:db8::1/128`).
   Using a /64 or larger is rejected by some receivers (too broad, abuse risk).

3. **Separate reputation** — IPv6 reputation is independent from IPv4. A new IPv6
   address starts with zero reputation. Warm up gradually (low volume first).

4. **Fallback** — keep IPv4 A record alongside AAAA. Some MTAs still don't support
   IPv6. MX resolution tries AAAA first (Happy Eyeballs) but falls back to A.

5. **DKIM/DMARC unaffected** — these are DNS-based, IP-independent. No changes needed.

6. **Test before production** — use `swaks --protocol smtp --server mail.domain.com -6`
   to force IPv6 connections and verify the full chain works.

## Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| No PTR for IPv6 | Mail rejected by major providers | Gate activation on PTR availability from VPS provider |
| Zero IPv6 reputation | Initial spam classification | Warm up: low volume for 2-4 weeks, monitor bounce rates |
| Cilium dual-stack bugs | Pod networking issues | Test in dev VMs first; keep IPv4 as primary path |
| NetworkPolicies IPv4-only | IPv6 traffic bypasses policies | Audit all policies for dual-stack CIDRs before enabling |
| VPS provider no IPv6 support | Cannot implement | Choose provider with native IPv6 + rDNS support |

## Decision outcome

- Use masquerade for outbound IPv6 (same as IPv4, single public IP)
- ULA for pod/service CIDRs (no public IPv6 routed into cluster)
- WireGuard tunnel stays IPv4 (PROXY protocol carries client IPv6)
- Gate mail IPv6 activation on PTR + SPF + reputation warmup
- Phase 1-2 can proceed immediately (internal, no external risk)
- Phase 3-4 require VPS provider IPv6 + DNS changes (external dependency)
