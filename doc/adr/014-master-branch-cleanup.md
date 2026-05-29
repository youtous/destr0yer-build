# ADR-014: Master branch cleanup

**Status**: Done

**Context**: The master branch contains legacy artifacts from the pre-K3S era:
- Root-level playbooks (`the-swarm.yml`, `destr0yers.yml`, `elastic.yml`,
  `mailserver.yml`, `nextcloud.yml`, `teamspeak.yml`, `update-users.yml`)
  that were replaced by `playbooks/*.yml` in the k3S branch
- Old-style role names with dashes (`docker-mailserver`, `elastic-filebeat`)
  alongside the underscore versions (`docker_mailserver`, `elastic_filebeat`)
- Legacy `hosts/` directory alongside `inventories/dev/`
- Legacy `group_vars/` at root alongside `inventories/dev/group_vars/`
- Missing roles from master not yet ported: `backup-postgresql`, `postgresql`
  (PostgreSQL support was incomplete on master anyway — "SSL NOT CONFIGURED")
- `services` role (Scaleway cleanup) — already ported as `scaleway_services`
  and archived

**Decision**: When merging k3S → master:
1. Delete all root-level playbooks (replaced by `playbooks/`)
2. Delete all dash-named roles (replaced by underscore versions)
3. Delete legacy `hosts/` and root `group_vars/` (replaced by `inventories/dev/`)
4. PostgreSQL: if needed, create a new `k8s_postgresql` role from scratch
   rather than porting the incomplete master version
5. Keep utility scripts (`bcrypt-passwd.sh`, `generate-X509-certificate.rb`) — still useful
