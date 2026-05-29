---
name: check-versions
description: >-
  Audit and update component versions across the project. Use when the user asks
  to check versions, find outdated dependencies, update Helm charts, container
  images, or Ansible roles, or mentions Renovate, version bump, or upgrade.
---

# Version Checking

## Quick start

Run the version audit script:

```bash
./scripts/check-versions.sh                # List all current versions
./scripts/check-versions.sh --check-updates # Check registries for newer versions
```

Requires: `yq`, `helm`, `curl`, `jq`. Optional: `crane` (for container image checks).

## What it covers

| Source | Location | Count |
|--------|----------|-------|
| Helm charts | `kluctl/**/helm-chart.yaml` | ~18 |
| Container images | `kluctl/**/*.yaml` (image: lines) | ~51 |
| K3S | `roles/k3s/defaults/main.yml` | 1 |
| Cilium | `roles/k3s_cilium/defaults/main.yml` | 1 |
| Cilium CLI | `roles/k8s_cilium_cli/defaults/main.yml` | 1 |
| CoreDNS | `roles/k3s/defaults/main.yml` | 1 |
| Dev tools | `.tool-versions` | ~7 |
| Ansible collections | `requirements.yml` | ~5 |
| Ansible roles | `requirements.yml` (pinned by SHA) | ~7 |

## Updating a component

### Helm chart

Edit `helm-chart.yaml`, update `chartVersion`:

```yaml
helmChart:
  chartVersion: "NEW_VERSION"
```

Then: `just render` to validate, `just deploy-only <path>` to apply.

### Container image

Update the image tag and SHA256 digest (Kyverno enforces digests):

```bash
crane digest docker.io/org/image:NEW_TAG
```

### Ansible-managed (K3S, Cilium)

Update the version variable in `roles/*/defaults/main.yml`, then `just k3s`.

### Dev tools

Update `.tool-versions`, then `just setup`.

## CI integration

GitHub Actions workflow `.github/workflows/version-check.yml` runs weekly (Monday 08:00 UTC).
When updates are detected, it creates/updates a GitHub issue labeled `version-check`
tagging maintainers from `MAINTAINERS`.

Trigger manually: Actions tab → "Version Check" → "Run workflow".

## Conventions

- All container images pinned to specific versions, never `:latest`
- Kyverno enforces SHA256 digest on all images
- Renovate handles automated PR creation for known version patterns
- This script catches what Renovate misses (Ansible roles, custom patterns)
