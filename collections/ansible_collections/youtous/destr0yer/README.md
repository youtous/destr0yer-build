# Ansible Collection: youtous.destr0yer

Reusable Ansible roles for hardened Debian infrastructure. Extracted from [destr0yer-build](https://github.com/youtous/destr0yer-build) for standalone use.

## Roles

| Role | Description |
|------|-------------|
| `youtous.destr0yer.ufw_smart_rules` | Declarative UFW firewall management — define target state, role reconciles existing rules (add missing, delete stale) |
| `youtous.destr0yer.users` | User and group management — create users, set SSH keys, manage profiles, remove deleted users |
| `youtous.destr0yer.logwatch` | Install and configure logwatch with cron scheduling |

## Requirements

- ansible-core >= 2.18.0
- Target OS: Debian 13+ / Ubuntu 24.04+

### Collection dependencies

Declared in `galaxy.yml` and installed automatically:

- `community.general` >= 13.0.0
- `ansible.posix` >= 2.1.0
- `ansible.utils` >= 5.0.0

## Installation

### From the destr0yer-build repository (bundled)

The collection ships at `collections/ansible_collections/youtous/destr0yer/`. Configure `ansible.cfg`:

```ini
[defaults]
collections_path = ./collections
```

### From a release artifact

```bash
ansible-galaxy collection install youtous-destr0yer-1.0.0.tar.gz
```

### From Galaxy (when published)

```bash
ansible-galaxy collection install youtous.destr0yer
```

## Usage

Reference roles by their Fully Qualified Collection Name (FQCN):

```yaml
- name: Configure firewall
  ansible.builtin.include_role:
    name: youtous.destr0yer.ufw_smart_rules
  vars:
    ufw_rules_criteria: from_ips
    ufw_rule_from_ips:
      - 10.0.0.0/8
    ufw_rule_parameters:
      rule: allow
      to_port: "22"
      proto: tcp
      comment: "SSH access"

- name: Manage users
  ansible.builtin.import_role:
    name: youtous.destr0yer.users
  vars:
    users:
      - username: deploy
        uid: 1100
        groups: ["sudo"]
        ssh_key:
          - "ssh-ed25519 AAAA..."

- name: Configure logwatch
  ansible.builtin.import_role:
    name: youtous.destr0yer.logwatch
  vars:
    logwatch_detail: Med
    logwatch_range: yesterday
    logwatch_cron_time: daily

```

## Role details

### ufw_smart_rules

Manages UFW rules declaratively. You define the target state (allowed IPs, ports, protocols) and the role:

1. Lists current UFW rules
2. Matches rules against your definition using JMESPath queries
3. Deletes rules that are no longer in the target state (highest index first to avoid shifting)
4. Adds rules that are missing

Key variables: `ufw_rules_criteria` (`from_ips` or `to_ips`), `ufw_rule_from_ips`, `ufw_rule_to_ips`, `ufw_rule_parameters`.

### users

Creates groups, users, configures SSH authorized keys, sets up shell profiles, and removes deleted users. Supports per-user groups, custom shells, home directory management.

Key variables: `users`, `users_deleted`, `groups_to_create`, `users_create_per_user_group`, `users_default_shell`.

### logwatch

Installs logwatch, deploys configuration template, replaces the default daily cron with a configurable one.

Key variables: `logwatch_detail`, `logwatch_range`, `logwatch_output`, `logwatch_format`, `logwatch_cron_time`.

## License

MIT — see individual role `LICENSE` files.
