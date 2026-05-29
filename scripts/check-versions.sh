#!/usr/bin/env bash
set -euo pipefail

# Checks all component versions and optionally queries for newer releases.
# Usage: ./scripts/check-versions.sh [--check-updates]
#
# Requires: yq, helm, curl, jq
# Optional: crane (for container image checks)

CHECK_UPDATES=false
[[ "${1:-}" == "--check-updates" ]] && CHECK_UPDATES=true

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

section() { echo -e "\n${BOLD}${CYAN}=== $1 ===${NC}"; }
row() { printf "  %-40s %s\n" "$1" "$2"; }
update_row() { printf "  %-40s %-20s -> ${GREEN}%s${NC}\n" "$1" "$2" "$3"; }

gh_latest() {
    curl -sf "https://api.github.com/repos/$1/releases/latest" | jq -r '.tag_name // empty' 2>/dev/null || true
}

check_gh_update() {
    local label="$1" current="$2" repo="$3"
    if $CHECK_UPDATES; then
        local latest
        latest=$(gh_latest "$repo")
        latest_clean="${latest#v}"
        current_clean="${current#v}"
        if [[ -n "$latest" && "$latest_clean" != "$current_clean" ]]; then
            update_row "$label" "$current" "$latest"
        fi
    fi
}

# --- Helm charts (Kluctl) ---
section "Helm Charts (Kluctl)"
while IFS= read -r chart_file; do
    name=$(yq -r '.helmChart.chartName // .helmChart.releaseName // .helmChart.repo' "$chart_file")
    # For OCI charts without chartName, derive name from repo URL
    if [[ "$name" == "null" || -z "$name" ]]; then
        name=$(yq -r '.helmChart.repo' "$chart_file" | sed 's|.*/||')
    fi
    version=$(yq -r '.helmChart.chartVersion' "$chart_file")
    repo=$(yq -r '.helmChart.repo' "$chart_file")
    row "$name" "$version"

    if $CHECK_UPDATES && [[ -n "$repo" && "$repo" != "null" ]]; then
        repo_name="check-${name//[^a-zA-Z0-9]/-}"
        if helm repo add "$repo_name" "$repo" --force-update &>/dev/null; then
            latest=$(helm search repo "$repo_name/$name" --output json 2>/dev/null | jq -r '.[0].version // empty')
            if [[ -n "$latest" && "$latest" != "$version" && "$latest" != "v$version" ]]; then
                update_row "$name" "$version" "$latest"
            fi
            helm repo remove "$repo_name" &>/dev/null || true
        fi
    fi
done < <(find "$REPO_ROOT/kluctl" -name "helm-chart.yaml" -type f | sort)

# --- Container images (Kluctl) ---
section "Container Images (Kluctl)"
grep -rh --exclude-dir='.helm-charts' '^\s*image:' "$REPO_ROOT/kluctl/" 2>/dev/null \
    | sed 's/.*image:\s*//' \
    | sed 's/"//g; s/'\''//g' \
    | sed 's/\s*$//' \
    | grep -v '{{' \
    | grep -v '^\s*$' \
    | sort -u | while read -r img; do

    # For digest-only images (no :tag), extract version from trailing comment
    comment_ver=""
    if [[ "$img" == *"#"* ]]; then
        comment_ver=$(echo "$img" | sed 's/.*#\s*//')
    fi
    img=$(echo "$img" | sed 's/\s*#.*//')

    # Strip @sha256: digest
    img_clean=$(echo "$img" | sed 's/@sha256:[a-f0-9]*//')

    # If stripping digest removed the only version info, use comment as tag
    if [[ "$img_clean" != *":"* && -n "$comment_ver" ]]; then
        img_clean="${img_clean}:${comment_ver}"
    fi

    # Normalize: add docker.io/ if no registry prefix
    if [[ "$img_clean" != *"/"*"/"* && "$img_clean" != *"."*"/"* ]]; then
        full_img="docker.io/library/$img_clean"
        [[ "$img_clean" == *"/"* ]] && full_img="docker.io/$img_clean"
    else
        full_img="$img_clean"
    fi

    if [[ "$full_img" != *":"* ]]; then
        continue
    fi

    name="${full_img%:*}"
    tag="${full_img##*:}"
    short_name=$(echo "$name" | sed 's|docker.io/library/||;s|docker.io/||')
    row "$short_name" "$tag"

    if $CHECK_UPDATES && command -v crane &>/dev/null; then
        base_tag=$(echo "$tag" | grep -oE '^v?[0-9]+\.[0-9]+' || true)
        if [[ -n "$base_tag" ]]; then
            if [[ "$tag" == *-alpine* ]]; then
                latest=$(crane ls "$name" 2>/dev/null | grep -E "^v?[0-9]+\.[0-9]+(\.[0-9]+)?-alpine$" | sort -V | tail -1 || true)
            elif [[ "$tag" == v* ]]; then
                latest=$(crane ls "$name" 2>/dev/null | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 || true)
            else
                latest=$(crane ls "$name" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -V | tail -1 || true)
            fi
            if [[ -n "$latest" && "$latest" != "$tag" ]]; then
                update_row "$short_name" "$tag" "$latest"
            fi
        fi
    fi
done

# --- Ansible-managed components ---
section "Ansible Roles — Host Tools"

declare -A ROLE_VERSIONS=(
    ["K3S"]="k3s_installation_release_version|roles/k3s/defaults/main.yml|k3s-io/k3s"
    ["Cilium (chart)"]="cilium_chart_version|roles/k3s_cilium/defaults/main.yml|cilium/cilium"
    ["Cilium CLI"]="k8s_cilium_cli_version|roles/k8s_cilium_cli/defaults/main.yml|cilium/cilium-cli"
    ["CoreDNS"]="k3s_coredns_container_image_version|roles/k3s/defaults/main.yml|"
    ["Monit"]="monit_version|roles/monit/defaults/main.yml|"
    ["Kopia"]="kopia_version|roles/kopia/defaults/main.yml|kopia/kopia"
    ["Alloy"]="alloy_version|roles/alloy/defaults/main.yml|grafana/alloy"
    ["Kluctl CLI"]="k8s_kluctl_version|roles/k8s_kluctl/defaults/main.yml|kluctl/kluctl"
    ["Helm"]="k8s_helm_version|roles/k8s_helm/defaults/main.yml|helm/helm"
    ["k9s"]="k8s_k9s_version|roles/k8s_k9s/defaults/main.yml|derailed/k9s"
    ["kube-bench"]="kube_bench_version|roles/audit_kube_bench/defaults/main.yml|aquasecurity/kube-bench"
    ["Gateway API CRDs"]="cilium_gateway_api_crd_version|roles/k3s_cilium/defaults/main.yml|kubernetes-sigs/gateway-api"
)

for label in "K3S" "Cilium (chart)" "Cilium CLI" "Gateway API CRDs" "CoreDNS" \
             "Alloy" "Kopia" "Monit" "kube-bench" \
             "Kluctl CLI" "Helm" "k9s"; do
    IFS='|' read -r var_name file gh_repo <<< "${ROLE_VERSIONS[$label]}"
    ver=$(yq -r ".$var_name" "$REPO_ROOT/$file" 2>/dev/null || echo "unknown")
    row "$label" "$ver"
    [[ -n "$gh_repo" ]] && check_gh_update "$label" "$ver" "$gh_repo"
done

# --- Dev tools (.tool-versions) ---
section "Dev Tools (.tool-versions)"
while IFS=' ' read -r tool version; do
    [[ -z "$tool" || "$tool" == "#"* ]] && continue
    row "$tool" "$version"
done < "$REPO_ROOT/.tool-versions"

# --- Ansible Galaxy collections ---
section "Ansible Galaxy Collections (requirements.yml)"
yq -r '.collections[]? | "\(.name) \(.version)"' "$REPO_ROOT/requirements.yml" 2>/dev/null | while read -r name version; do
    row "$name" "$version"
done

# --- Ansible Galaxy roles (pinned by SHA) ---
section "Ansible Galaxy Roles (requirements.yml)"
yq -r '.roles[]? | "\(.name) \(.version)"' "$REPO_ROOT/requirements.yml" 2>/dev/null | while read -r name sha; do
    row "$name" "${sha:0:12}..."
done

# --- Summary ---
section "Summary"
helm_count=$(find "$REPO_ROOT/kluctl" -name "helm-chart.yaml" -type f | wc -l)
image_count=$(grep -rh --exclude-dir='.helm-charts' '^\s*image:' "$REPO_ROOT/kluctl/" 2>/dev/null \
    | sed 's/.*image:\s*//' | sed 's/"//g' | sed 's/\s*#.*//' | sed 's/@sha256:[a-f0-9]*//' \
    | grep -v '{{' | grep -v '^\s*$' | sort -u | wc -l)
role_count="${#ROLE_VERSIONS[@]}"
tool_count=$(wc -l < "$REPO_ROOT/.tool-versions")
galaxy_roles=$(yq -r '.roles | length' "$REPO_ROOT/requirements.yml")
galaxy_cols=$(yq -r '.collections | length' "$REPO_ROOT/requirements.yml")

echo -e "  Helm charts:         ${BOLD}$helm_count${NC}"
echo -e "  Container images:    ${BOLD}$image_count${NC}"
echo -e "  Ansible host tools:  ${BOLD}$role_count${NC}"
echo -e "  Dev tools:           ${BOLD}$tool_count${NC}"
echo -e "  Galaxy roles:        ${BOLD}$galaxy_roles${NC}"
echo -e "  Galaxy collections:  ${BOLD}$galaxy_cols${NC}"

if ! $CHECK_UPDATES; then
    echo -e "\n  ${YELLOW}Run with --check-updates to query for newer versions.${NC}"
fi
