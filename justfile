# destr0yer-build — K3S cluster management
# Run `just --list` to see all available recipes

set dotenv-load
set shell := ["bash", "-lc"]

# Environment — single source of truth for inventory path + kluctl target
# Sourced from .env ENV, override with: just env=prod deploy
env := env_var_or_default("ENV", "dev")

# Dev SSH — uses ~/.ssh/config (run `just ssh-config` once to set up)
# Before `just configure`: use `just ssh_user=vagrant k9s`
ssh_user := env_var_or_default("SSH_USER", "walle")
ctrl_ssh_host := env_var_or_default("CTRL_SSH_HOST", "ctrl.k3s.dev.local")
_ssh_ctrl := "ssh -t " + ssh_user + "@" + ctrl_ssh_host

# ─── Setup ───────────────────────────────────────────────────────────

# Bootstrap all development tools
setup: _tools-install _pip-install _galaxy-install
    @echo "✓ Dev environment ready"

# Register asdf plugins from .tool-versions
_plugins-register dir="./":
    #!/bin/sh
    echo "→ Registering asdf plugins"
    awk '{print $1}' {{dir}}.tool-versions | while read plugin; do
        asdf plugin add "$plugin" 2>&1 | grep -q "already added" || true
    done
    echo "→ Syncing plugin updates"
    asdf plugin update --all

# Install pinned tool versions via asdf
_tools-install: _plugins-register
    asdf install

# Install Python dependencies via pipenv
_pip-install:
    pip install pipenv
    python -m pipenv install --dev

# Install Ansible Galaxy requirements
_galaxy-install:
    python -m pipenv run ansible-galaxy install -r requirements.yml --force

# ─── Vault & Secrets ────────────────────────────────────────────────

# Load vault password interactively
vault-login:
    #!/usr/bin/env fish
    echo "Please enter your VAULT Password: "
    read -s VAULT_PASSWORD_INPUT
    set -Ux VAULT_PASSWORD "$VAULT_PASSWORD_INPUT"
    echo "✓ Vault password set"

# Edit an encrypted vault file
vault-edit file:
    python -m pipenv run ansible-vault edit {{file}} --vault-password-file "./.vault_password"

# Edit a SOPS-encrypted file (kluctl targets)
sops-edit file:
    sops {{file}}

# Encrypt a file with ansible-vault
vault-encrypt file:
    python -m pipenv run ansible-vault encrypt {{file}} --vault-password-file "./.vault_password"

# Decrypt a file with ansible-vault
vault-decrypt file:
    python -m pipenv run ansible-vault decrypt {{file}} --vault-password-file "./.vault_password"


# ─── Playbooks ───────────────────────────────────────────────────────

# Log directory for Ansible runs (git-ignored)
_log_dir := "logs"
_timestamp := `date +%Y%m%d-%H%M%S`

# Run an ansible-playbook command with logging to logs/<playbook>-<timestamp>.log
[no-exit-message]
_ansible-play playbook inventory *args:
    #!/usr/bin/env bash
    set -uo pipefail
    mkdir -p {{_log_dir}}
    logfile="{{_log_dir}}/$(basename {{playbook}} .yml)-{{_timestamp}}.log"
    echo "→ Logging to $logfile"
    ANSIBLE_FORCE_COLOR=true python -m pipenv run ansible-playbook -i {{inventory}} {{playbook}} \
        --vault-password-file "./.vault_password" {{args}} 2>&1 | tee "$logfile"
    exit ${PIPESTATUS[0]}

# [dev] Provision new servers (run once, as root)
provision *args:
    just _ansible-play playbooks/00-provision.yml inventories/{{env}}/base-nodes.yml {{args}}

# [dev] Configure servers (system setup)
configure *args:
    just _ansible-play playbooks/01-configure.yml inventories/{{env}}/base-nodes.yml {{args}}

# [dev] Deploy K3S cluster
k3s *args:
    just _ansible-play playbooks/02-k3s.yml inventories/{{env}}/k3s-cluster.yml {{args}}

# ─── SOPS & Secrets ────────────────────────────────────────────────

# Generate an age keypair for SOPS encryption
sops-init:
    #!/usr/bin/env bash
    set -euo pipefail
    keyfile="${SOPS_AGE_KEY_FILE:-.keys/${ENV:-dev}-sops.age}"
    mkdir -p "$(dirname "$keyfile")"
    if [ -f "$keyfile" ]; then
        echo "Age key already exists at $keyfile"
        grep "public key:" "$keyfile"
        exit 0
    fi
    age-keygen -o "$keyfile"
    echo ""
    echo "Public key:"
    grep "public key:" "$keyfile"
    echo ""
    echo "Next steps:"
    echo "  1. Update .sops.yaml with the public key above"
    echo "  2. Store the private key in vault:"
    echo "     echo 'sops_age_private_key: \"'$(grep AGE-SECRET $keyfile)'\"' > inventories/${ENV:-dev}/group_vars/all/vault-sops.yml"
    echo "     just vault-encrypt inventories/${ENV:-dev}/group_vars/all/vault-sops.yml"
    echo "  3. Run 'just sops-unlock' on other machines to extract the key for local use"

# Extract age private key from vault into $SOPS_AGE_KEY_FILE
sops-unlock:
    #!/usr/bin/env bash
    set -euo pipefail
    keyfile="${SOPS_AGE_KEY_FILE:-.keys/${ENV:-dev}-sops.age}"
    mkdir -p "$(dirname "$keyfile")"
    python -m pipenv run ansible-vault view inventories/${ENV:-dev}/group_vars/all/vault-sops.yml \
        --vault-password-file "./.vault_password" \
        | grep -oP '(?<=sops_age_private_key: ")[^"]+' > "$keyfile"
    echo "✓ Age key written to $keyfile"

# ─── Kluctl (K8S deployments) ────────────────────────────────────────
# Kluctl runs on ctrl as the operator user (no root). Uses operator kubeconfig (not admin).
# Workspace synced to ~/destr0yer-build/ on ctrl for persistence + SSH debugging.

# [dev] Sync full workspace to ctrl for kluctl operations and SSH debugging
sync:
    rsync -az --delete \
        --exclude='.git' --exclude='.dev' --exclude='*/vault*.yml' \
        --exclude='.vagrant' --exclude='node_modules' \
        -e ssh \
        ./ {{ssh_user}}@{{ctrl_ssh_host}}:~/destr0yer-build/
    @echo "✓ Workspace synced to {{ssh_user}}@{{ctrl_ssh_host}}:~/destr0yer-build/"

# Render templates offline (no cluster needed, runs locally)
render *args="":
    kluctl render -t {{env}} --project-dir kluctl/ --offline-kubernetes --kubernetes-version 1.36 {{args}}

# [dev] Preview K8S changes before applying
diff *args="":
    just _ansible-play playbooks/kluctl-ops.yml inventories/{{env}}/k3s-cluster.yml -e kluctl_command=diff -e kluctl_target={{env}} {{args}}

# [dev] Deploy all K8S components
deploy *args="":
    just _ansible-play playbooks/kluctl-ops.yml inventories/{{env}}/k3s-cluster.yml -e kluctl_command=deploy -e kluctl_target={{env}} {{args}}

# [dev] Deploy a specific component (e.g., just deploy-only observability/loki)
deploy-only path *args="":
    just _ansible-play playbooks/kluctl-ops.yml inventories/{{env}}/k3s-cluster.yml -e kluctl_command=deploy -e kluctl_target={{env}} -e kluctl_include_dirs={{path}} {{args}}

# [dev] Remove orphaned K8S resources
prune:
    just _ansible-play playbooks/kluctl-ops.yml inventories/{{env}}/k3s-cluster.yml -e kluctl_command=prune -e kluctl_target={{env}}

# [dev] Sync workspace to ctrl and print the kluctl command for manual SSH execution
deploy-manual command="deploy" *args="":
    just _ansible-play playbooks/kluctl-ops.yml inventories/{{env}}/k3s-cluster.yml -e kluctl_command={{command}} -e kluctl_target={{env}} -e kluctl_execute=false -e 'kluctl_extra_args={{args}}'

# ─── Dev Tools ──────────────────────────────────────────────────────

# Configure k8s.home + VM DNS entries in local /etc/hosts
dev-dns:
    python -m pipenv run ansible-playbook playbooks/dev-dns.yml --become

# Start mailpit SMTP catcher via podman on the host (catches all outbound mail from VMs)
# SMTP on :1025, Web UI on :8025
mailpit:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Starting mailpit via podman..."
    echo "  SMTP: 0.0.0.0:1025"
    echo "  Web UI: http://localhost:8025"
    podman run --rm --name mailpit \
        -p 1025:1025 -p 8025:8025 \
        docker.io/axllent/mailpit:v1.22.3

# Stop mailpit container
mailpit-stop:
    podman stop mailpit 2>/dev/null || echo "mailpit not running"

# ─── Dev cluster access ────────────────────────────────────────────

# [dev] Open k9s on ctrl (operator kubeconfig)
k9s:
    {{_ssh_ctrl}} 'k9s'

# [dev] Run kubectl on ctrl (operator kubeconfig)
kubectl *args:
    {{_ssh_ctrl}} 'kubectl {{args}}'

# [dev] Break-glass: kubectl with admin kubeconfig (emergency only)
kubectl-admin *args:
    {{_ssh_ctrl}} 'breakglass-kubectl {{args}}'

# [dev] Break-glass: k9s with admin kubeconfig (emergency only)
k9s-admin:
    {{_ssh_ctrl}} 'breakglass-k9s'

# [dev] Run garage CLI inside garage-0 pod (e.g., just garage status)
garage *args:
    {{_ssh_ctrl}} 'kubectl exec -n garage garage-0 -- /garage {{args}}'

# ─── Linting & Testing ──────────────────────────────────────────────

# Run pre-commit hooks on all files
lint:
    python -m pipenv run pre-commit run --all-files --show-diff-on-failure

# Run ansible-lint
ansible-lint:
    python -m pipenv run ansible-lint

# [dev] Run integration tests against deployed cluster
test-integration:
    just _ansible-play playbooks/99-integration-tests.yml \
        inventories/{{env}}/base-nodes.yml \
        -i inventories/{{env}}/k3s-cluster.yml

# [dev] Validate UFW firewall state matches expectations
test-firewall:
    just _ansible-play playbooks/98-firewall-audit.yml \
        inventories/{{env}}/base-nodes.yml \
        -i inventories/{{env}}/k3s-cluster.yml \
        -e server_environment={{env}}

# ─── Security Audit ─────────────────────────────────────────────────

# Audit K3S node config against CIS benchmark
audit-node host:
    ssh {{host}} "kube-bench run --benchmark k3s-cis-1.7 --json" | jq '.Totals'

# Audit cluster workloads against NSA/CISA + MITRE frameworks
audit-cluster:
    kubescape scan framework nsa,mitre --submit=false --format pretty-printer

# ─── SSH Keys ───────────────────────────────────────────────────────

# [dev] Generate a dev SSH keypair for Vagrant/test VMs (stored in workspace)
ssh-keygen:
    #!/bin/sh
    KEY_PATH=".dev/id_ed25519"
    mkdir -p .dev
    if [ -f "$KEY_PATH" ]; then
        echo "Key already exists: $KEY_PATH"
        echo "Public key:"
        cat "${KEY_PATH}.pub"
    else
        ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "destr0yer-dev"
        echo "Key generated: $KEY_PATH"
        echo "Public key:"
        cat "${KEY_PATH}.pub"
    fi

# [dev] Configure SSH hosts for Vagrant VMs in ~/.ssh/config
ssh-config:
    #!/bin/sh
    KEY_PATH="$(pwd)/.dev/id_ed25519"
    BLOCK_START="# BEGIN destr0yer-dev"
    BLOCK_END="# END destr0yer-dev"
    CONFIG="$HOME/.ssh/config"
    mkdir -p "$HOME/.ssh"
    # Remove existing block if present
    if grep -q "$BLOCK_START" "$CONFIG" 2>/dev/null; then
        sed -i "/$BLOCK_START/,/$BLOCK_END/d" "$CONFIG"
    fi
    cat >> "$CONFIG" <<EOF
    $BLOCK_START
    Host *.k3s.dev.local
        User {{ssh_user}}
        IdentityFile $KEY_PATH
        IdentitiesOnly yes
        StrictHostKeyChecking no
        UserKnownHostsFile /dev/null
    Host ctrl.k3s.dev.local
        HostName 192.168.56.10
    Host worker.k3s.dev.local
        HostName 192.168.56.11
    $BLOCK_END
    EOF
    echo "SSH config updated for Vagrant VMs"

# ─── Vagrant (dev) ──────────────────────────────────────────────────

# Install vagrant-libvirt plugin and configure KVM/libvirt
vagrant-setup:
    #!/bin/sh
    # Check dnsmasq is installed (required by libvirt for VM DHCP/DNS on virbr0)
    if ! command -v dnsmasq >/dev/null 2>&1; then
        echo "ERROR: dnsmasq is not installed. Install it with your package manager:"
        echo "  Arch: sudo pacman -S dnsmasq"
        echo "  Debian: sudo apt install dnsmasq"
        exit 1
    fi
    vagrant plugin uninstall vagrant-vbguest 2>/dev/null || true
    vagrant plugin install vagrant-libvirt
    sudo systemctl enable --now libvirtd
    sudo usermod -aG libvirt $(whoami)
    echo "Log out and back in for the libvirt group to take effect"

# Start Vagrant VMs (parallel, KVM/libvirt)
vagrant-up:
    #!/bin/sh
    VAGRANT_DEFAULT_PROVIDER=libvirt vagrant up --parallel
    # Idempotent /etc/hosts update — skip if already correct
    if grep -q "ctrl.k3s.dev.local" /etc/hosts 2>/dev/null; then
        echo "✓ /etc/hosts already configured"
    else
        echo "Updating /etc/hosts..."
        sudo sed -i '/# BEGIN destr0yer-dev/,/# END destr0yer-dev/d' /etc/hosts
        printf "# BEGIN destr0yer-dev\n192.168.56.10 ctrl.k3s.dev.local\n192.168.56.11 worker.k3s.dev.local\n# END destr0yer-dev\n" | sudo tee -a /etc/hosts > /dev/null
        echo "✓ /etc/hosts updated"
    fi

# Stop Vagrant VMs
vagrant-halt:
    vagrant halt

# Destroy Vagrant VMs and clean up libvirt volumes
vagrant-destroy:
    #!/bin/sh
    vagrant destroy -f 2>/dev/null || true
    just _libvirt-cleanup
    rm -rf .vagrant/machines
    echo "✓ Vagrant VMs and volumes cleaned up"

# Destroy + recreate VMs from scratch
vagrant-reset:
    just vagrant-destroy
    just vagrant-up

# Remove orphaned libvirt volumes left by vagrant-libvirt (extra_disks)
_libvirt-cleanup:
    #!/bin/sh
    if ! command -v virsh >/dev/null 2>&1; then
        exit 0
    fi
    for pool in default destr0yer; do
        for vol in $(sudo virsh vol-list --pool "$pool" 2>/dev/null | grep 'destr0yer_' | awk '{print $1}'); do
            echo "  Removing stale volume: $vol (pool: $pool)"
            sudo virsh vol-delete --pool "$pool" "$vol" 2>/dev/null || true
        done
    done
