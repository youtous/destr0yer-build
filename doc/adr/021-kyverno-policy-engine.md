# ADR-021: Kyverno — policy engine for admission control

**Status**: Done

**Context**: PSA (PodSecurityAdmission) provides coarse-grained pod security
(`privileged`, `baseline`, `restricted`) but cannot enforce custom rules like
"block `:latest` tags" or "only pull from our registry". OpenShift uses
Security Context Constraints (SCCs) for this; the K8S-native equivalent is
a policy engine.

**Options evaluated**:

| | Kyverno | OPA Gatekeeper |
|---|---|---|
| Language | YAML (declarative) | Rego (custom DSL) |
| RAM | ~30 MB | ~200 MB |
| Learning curve | Low (just YAML) | High (learn Rego) |
| Mutation | Yes | Limited |
| Image verification | Yes (cosign, Notary) | Plugin |
| Generate resources | Yes | No |

**Decision**: Kyverno. YAML-native, lightweight, can both validate AND mutate.

**Policies to enforce**:

```yaml
# Block :latest image tags at admission time
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest-tag
spec:
  validationFailureAction: Enforce
  rules:
    - name: require-image-tag
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        message: "Image tag ':latest' is not allowed."
        pattern:
          spec:
            containers:
              - image: "!*:latest"

# Only allow images from our private registry
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-image-registries
spec:
  validationFailureAction: Enforce
  rules:
    - name: validate-registries
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        message: "Images must come from the internal registry."
        pattern:
          spec:
            containers:
              - image: "registry.internal.cluster/*"

# Force resource limits on every container
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resource-limits
spec:
  validationFailureAction: Enforce
  rules:
    - name: check-limits
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        message: "CPU and memory limits are required."
        pattern:
          spec:
            containers:
              - resources:
                  limits:
                    memory: "?*"
                    cpu: "?*"

# Mutate: inject default security context
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: default-security-context
spec:
  rules:
    - name: add-run-as-non-root
      match:
        any:
          - resources:
              kinds: [Pod]
      mutate:
        patchStrategicMerge:
          spec:
            securityContext:
              runAsNonRoot: true
              seccompProfile:
                type: RuntimeDefault
```

```yaml
# Block hostPath volume mounts (namespace escape vector — Perplexity finding)
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: deny-host-path
spec:
  validationFailureAction: Enforce
  rules:
    - name: deny-host-path-volumes
      match:
        any:
          - resources:
              kinds: [Pod]
      exclude:
        any:
          - resources:
              namespaces: [kube-system, cilium, monitoring]
      validate:
        message: "hostPath volumes are not allowed in application namespaces."
        pattern:
          spec:
            =(volumes):
              - X(hostPath): "null"

# Require image digest for critical workloads (supply chain protection)
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-image-digest
spec:
  validationFailureAction: Enforce
  rules:
    - name: require-digest
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [mail, auth, security]
      validate:
        message: "Critical workloads must use image digest (image@sha256:...)."
        pattern:
          spec:
            containers:
              - image: "*@sha256:*"
```

**Deployment**: Via Kluctl in `security/kyverno/`. Helm chart for Kyverno
itself, then ClusterPolicy manifests for each rule.

**Relationship with PSA**: Kyverno replaces PSA. PSA is coarse (entire
namespace is `restricted` or `privileged`). Kyverno is per-rule, per-resource,
and can mutate (inject defaults) not just reject.
