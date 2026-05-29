# ADR-020: Namespace templates — security by default

**Status**: Done

**Context**: In OpenShift, every new project (namespace) is created from a
template that includes default security policies. Without this, namespaces
are born wide-open — no network restrictions, no resource limits, no pod
security constraints. This is a common source of misconfigurations.

**Decision**: Every namespace created via Kluctl includes a `namespace-defaults/`
component that applies security baselines automatically.

**What gets applied to every namespace**:

```yaml
# 1. Default-deny NetworkPolicy (Cilium)
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny
spec:
  endpointSelector: {}
  ingress: []
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP

# 2. LimitRange (prevent unbounded pods)
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
spec:
  limits:
    - type: Container
      default:
        cpu: 500m
        memory: 256Mi
      defaultRequest:
        cpu: 100m
        memory: 128Mi

# 3. ResourceQuota (cap total namespace consumption)
apiVersion: v1
kind: ResourceQuota
metadata:
  name: default-quota
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 2Gi
    limits.cpu: "4"
    limits.memory: 4Gi
    pods: "20"
```

**Implementation via Kluctl**:
```
kluctl/
  security/
    namespace-defaults/
      deployment.yaml           # loops over all app namespaces
      networkpolicy.yaml.j2
      limitrange.yaml.j2
      resourcequota.yaml.j2
```

Kluctl's Jinja2 templating loops over a list of namespaces defined in the
target vars. Each namespace gets the same baseline. Per-namespace overrides
(e.g., higher limits for monitoring) are set via target variables.

**Inspiration**: OpenShift project templates, which enforce this pattern
at the platform level.
