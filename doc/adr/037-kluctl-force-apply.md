# ADR-037: Kluctl force-apply by default

**Status**: Done

**Context**: Kluctl uses Kubernetes Server-Side Apply (SSA) with a "live and
let live" philosophy — it voluntarily yields field ownership when another
manager claims a field. In practice, this caused a critical bug: after the
initial deploy, kluctl lost ownership of `data` fields in ConfigMaps and
Secrets. Subsequent deploys could not update application configuration
(Grafana OIDC URLs, HAProxy settings, Authelia config, etc.) because kluctl
saw no conflict on fields it no longer owned.

**Root cause**: SSA tracks ownership per-field via `managedFields`. When
kluctl's conflict resolution algorithm encounters a field owned by another
manager (even `kubectl-client-side-apply` from a one-off debug patch), it
gives up ownership silently. Once lost, ownership is never reclaimed unless
force-apply is used. The default `--short-output` flag hides any warnings
about lost ownership, making the problem invisible.

**Impact**: 446 out of 447 kluctl-managed resources had zero field ownership
on their `data`/`spec` fields. Any configuration change deployed via
`just deploy` was silently ignored by the cluster.

**Decision**: Always force-apply.

1. **`conflictResolution` in `kluctl/deployment.yaml`** (declarative, in-repo):
   ```yaml
   conflictResolution:
     - fieldPathRegex: ".*"
       action: force-apply
   ```
   Ensures kluctl reclaims ownership whenever a conflict is detected on any
   field, regardless of which manager currently owns it.

2. **`--force-apply` default in `playbooks/kluctl-ops.yml`** (operational):
   ```yaml
   kluctl_extra_args: "--force-apply"
   ```
   Passed to every `just deploy`, `just deploy-only`, `just diff`, and
   `just prune` invocation. This forces re-application of all fields on
   every deploy, not just conflicting ones.

**Trade-offs**:

- **Pro**: Eliminates an entire class of silent deployment failures. Kluctl
  is the sole deployer in this stack — no other GitOps tool or operator
  should own application configuration fields.
- **Pro**: Makes `just deploy` idempotent in the strongest sense: the cluster
  always converges to the declared state.
- **Con**: If an operator legitimately manages a field (e.g. HPA setting
  `spec.replicas`), force-apply will overwrite it. Acceptable here because
  we don't use HPA and all scaling is declarative.
- **Con**: Slightly more API server work per deploy (re-applies unchanged
  resources). Negligible for a single-cluster setup.

**Additional fix — `just deploy-only` tag resolution**:

A secondary bug was discovered: the playbook used `-I` (kluctl shorthand
for `--include-tag`) but passed a directory path like
`observability/promgraf`. Since kluctl auto-generates tags from directory
names (e.g. `promgraf`, `observability`, `chart`), the full path never
matched any tag. As a result, `just deploy-only <path>` silently deployed
nothing — no error, no warning.

Fix: the playbook now extracts the basename of the path and passes it as a
tag: `observability/promgraf` → `-I promgraf`. This matches the
auto-generated kluctl tag and correctly filters the deploy scope.

**Alternatives considered**:

- **Annotate individual resources** (`kluctl.io/force-apply: "true"`):
  requires touching every manifest. Fragile — new resources would need the
  annotation too.
- **Use `--include-deployment-dir`**: kluctl provides this flag for
  directory-based filtering, but in v2.27.0 it does not match nested
  deployment includes correctly. Tag-based filtering is the reliable
  alternative.
- **Fix root cause in kluctl**: the field ownership loss may be a kluctl
  bug (v2.27.0). Even if fixed upstream, force-apply is a safer default
  for a single-deployer stack.
- **Do nothing, use `--force-apply` only when needed**: the problem is
  silent and only discovered when a config change is ignored. Unacceptable
  for production.
