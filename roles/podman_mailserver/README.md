# podman_mailserver

Standalone deployment of [docker-mailserver](https://docker-mailserver.github.io/docker-mailserver/latest/)
v15 via rootless Podman Quadlet with pasta networking. Designed for simple,
secure self-hosting on a single node without requiring Kubernetes.

Can also serve as a stepping stone toward a full Kubernetes deployment
(`kluctl/mail/`) — see [Transition to Kubernetes](#transition-to-kubernetes).

The role deploys three containers in a shared Podman pod:

- **docker-mailserver** — SMTP/IMAP with TLS, Rspamd, fail2ban
- **nginx-mail** — HTTPS for MTA-STS policy + autodiscover/autoconfig reverse proxy
- **autodiscover** — `wdes/mail-autodiscover-autoconfig` for Outlook/Thunderbird/Apple Mail

All containers run as a dedicated system user (`mail-dms`) via user-level Quadlet
in `~/.config/containers/systemd/` with `Network=pasta`, following the same
rootless pattern as `cloud_relay`.

## Architecture

```
Internet
  │
  ├── :25/:465/:587/:993 → docker-mailserver (DMS v15, TLS + fail2ban)
  │
  └── :80/:443 → nginx-mail
                    ├── mta-sts.<domain>/.well-known/mta-sts.txt  (static)
                    ├── autoconfig.<domain>/ ──► autodiscover:8080 (reverse proxy)
                    └── autodiscover.<domain>/ ──► autodiscover:8080 (reverse proxy)

Storage: /srv/podman/mailserver/  (LV mount, managed by disks_lvm_management)
  ├── mail-data/     → /var/mail           (Maildir)
  ├── mail-state/    → /var/mail-state     (Postfix/Dovecot/fail2ban state)
  ├── mail-log/      → /var/log/mail       (logs)
  ├── config/        → /tmp/docker-mailserver (accounts, aliases, DKIM, Rspamd)
  ├── tls/           → /etc/dms/tls + /etc/nginx/tls (shared wildcard cert)
  └── nginx/         → Nginx config + MTA-STS policy files
```

## Prerequisites

Applied before this role:

| What | Where | Why |
|------|-------|-----|
| LVM mount at `/srv/podman` | `disks_lvm_management` in `00-provision` | Dedicated storage for all Podman data |
| Podman | `system_packages` in `01-configure` | Container runtime |
| `sysctl_net_ipv4_ip_unprivileged_port_start: '25'` | `sysctl_configuration` in `01-configure` | Allow rootless binding to ports 25+ |

The role creates a dedicated system user (`mail-dms`, UID 5200), configures
subuid/subgid, and enables lingering for boot persistence. It asserts the LV
mount exists and fails early if missing.

## Playbook usage

```sh
# Deploy
just ansible-playbook playbooks/03-podman-mailserver.yml

# Teardown (keep mail data for migration to K8S)
just ansible-playbook playbooks/03-podman-mailserver.yml -e podman_mailserver_state=absent

# Teardown + purge all data
just ansible-playbook playbooks/03-podman-mailserver.yml \
  -e podman_mailserver_state=absent \
  -e podman_mailserver_teardown_purge_data=true
```

## Required variables

All secrets go in Ansible Vault (`host_vars/<host>/vault.yml` or
`group_vars/podman_mailservers/vault.yml`).

### Inventory (host_vars)

```yaml
podman_mailserver_domain: "example.com"
podman_mailserver_hostname: "mail.example.com"
```

### LVM (host_vars, for disks_lvm_management)

```yaml
disk_partitions_to_create:
  - device: /dev/sdb
    part_number: 1
    flags: [lvm]
    name: "podman_data"

volume_groups_to_create:
  - pvs: "/dev/disk/by-partlabel/{{ 'podman_data' | hash('md5') }}"
    vg: "vg-podman"

logical_volume_groups_to_create:
  - vg: "vg-podman"
    lv: "lv-podman"
    size: "100%FREE"

filesystems_to_create:
  - dev: /dev/mapper/vg--podman-lv--podman
    fstype: xfs
    mount_path: /srv/podman
    mount_opts: "defaults,noatime,nofail"
```

### Vault (secrets)

```yaml
# TLS — wildcard Let's Encrypt certificate (inline PEM)
# podman_mailserver_tls_cert: <fullchain PEM from Let's Encrypt>
# podman_mailserver_tls_key: <private key PEM from Let's Encrypt>

# Domains, accounts, aliases, DKIM
podman_mailserver_domains:
  - domain: "example.com"
    mta_sts:                           # optional, see DNS records section
      mode: "enforce"                  # testing | enforce | none
      max_age: 604800                  # seconds (~7 days)
      mx_entries:
        - "mail.example.com"
    accounts:
      - username: "user1"
        bcrypt_password: "$2b$12$..."  # doveadm pw -s BLF-CRYPT
        quota_mb: 500                  # optional
      - username: "postmaster"
        bcrypt_password: "$2b$12$..."
    aliases:
      - alias: "abuse@example.com"
        to: "postmaster@example.com"
      - alias: "@example.com"         # catch-all (optional)
        to: "user1@example.com"
    regexp_aliases:                     # optional, pcre patterns
      - pattern: "/^bounce-.*@example\\.com$/"
        to: "postmaster@example.com"
    dkim_private: |                          # optional, PEM private key for Rspamd DKIM signing
      <RSA private key PEM content>
    dkim_public: |                         # optional, PEM public key for DNS reference
      -----BEGIN PUBLIC KEY-----
      MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA...
      -----END PUBLIC KEY-----
    receive_bans:                      # optional
      - "spammer@evil.com"
    send_bans: []                      # optional
```

## Optional variables

| Variable | Default | Description |
|----------|---------|-------------|
| `podman_mailserver_user` | `mail-dms` | Rootless Podman system user |
| `podman_mailserver_uid` | `5200` | UID for the rootless user |
| `podman_mailserver_base_path` | `/srv/podman` | LV mount point |
| `podman_mailserver_enable_fail2ban` | `true` | DMS built-in fail2ban (nftables, container-scoped) |
| `podman_mailserver_enable_rspamd` | `true` | Rspamd spam filtering + DKIM signing |
| `podman_mailserver_enable_clamav` | `false` | ClamAV antivirus (adds ~200MB RAM) |
| `podman_mailserver_tls_level` | `modern` | TLS version floor (`modern` = TLS 1.2+) |
| `podman_mailserver_log_level` | `info` | DMS log level |
| `podman_mailserver_mailbox_size_limit` | `1073741824` | 1 GB per mailbox |
| `podman_mailserver_message_size_limit` | `12000000` | ~12 MB per message |
| `podman_mailserver_ufw_from_ips` | `["0.0.0.0/0", "::/0"]` | Restrict UFW rules to specific source CIDRs |
| `podman_mailserver_state` | `present` | `present` to deploy, `absent` to teardown |
| `podman_mailserver_teardown_purge_data` | `false` | Delete mail data on teardown |
| `podman_mailserver_migration_enabled` | `false` | Run v10 data import tasks |
| `podman_mailserver_migration_source` | `/var/mail-backup` | Path to v10 data on target host |

## Security

- **Rootless Podman** with user-level Quadlet (same model as `cloud_relay`)
- **Network=pasta** — preserves source IPs for fail2ban and logging
- **fail2ban** with `NET_ADMIN` — bans apply within the container network namespace
- **TLS**: wildcard Let's Encrypt cert, `TLS_LEVEL=modern` (TLS 1.2+)
- **PERMIT_DOCKER=none** — all mail submission requires SASL authentication
- **SPOOF_PROTECTION=1** — sender address validation
- **POSTSCREEN_ACTION=enforce** — DNSBL-based filtering at SMTP level
- **ReadOnly=true** on Nginx and autodiscover containers
- **user-patches.sh** runs `apt-get upgrade` on every DMS start (security backports)

## Fail2ban

The role uses DMS's **built-in fail2ban** (runs inside the container). Because the
pod uses rootless Podman with `Network=pasta`, fail2ban operates within the
container's network namespace — bans are scoped to the pasta interface. Source
IPs are preserved by pasta, so fail2ban sees real client IPs and bans work
correctly at the container level.

DMS v15 uses nftables as the fail2ban backend. Default jails include `postfix`,
`dovecot`, and `postfix-sasl`. Custom jails can be added via
`config/fail2ban-jail.cf` in the DMS config volume.

If host-level fail2ban is also running (role `fail2ban`), there is no conflict —
the DMS fail2ban manages its own nftables chains inside the container namespace.
For additional host-level jails reading DMS logs, use `fail2ban_additional` with
log path `/srv/podman/mailserver/mail-log/`.

## TLS certificate management

The role deploys TLS certificates from Ansible Vault variables
(`podman_mailserver_tls_cert` and `podman_mailserver_tls_key`) but **does not
manage certificate provisioning or renewal**. This is intentionally left to the
operator — choose whichever method fits your setup:

| Method | How it works |
|--------|-------------|
| **certbot (manual DNS-01)** | `certbot certonly --manual --preferred-challenges dns`, copy PEM to vault, re-run playbook |
| **certbot (automated DNS-01)** | Use a DNS plugin (e.g. `certbot-dns-cloudflare`, `certbot-dns-desec`) with a cron/systemd timer, then push to vault or sync certs directly |
| **acme.sh** | Lightweight alternative to certbot with built-in DNS API support for many providers |
| **cert-manager (on K3S)** | If you run a K3S cluster alongside, cert-manager can issue certs via DNS-01 and export them to a Secret; a script syncs the PEM into vault or directly to the host |
| **Vault-managed** | Store certs in Ansible Vault, renew manually when needed, re-run the playbook |

Regardless of the method, the workflow is always:

1. Obtain or renew the certificate (wildcard `*.example.com` recommended)
2. Update `podman_mailserver_tls_cert` and `podman_mailserver_tls_key` in vault
   (or deploy certs directly to `/srv/podman/mailserver/tls/` and restart)
3. Re-run the playbook — handlers automatically restart DMS and Nginx on cert change

## Migration from DMS v10

### Overview

The migration spans five major DMS releases (v10 → v11 → v12 → v13 → v14 → v15).
The role handles the data-level migration automatically. Key transformations:

| What | v10 format | v15 format | Handled by role |
|------|-----------|-----------|-----------------|
| Mail data (Maildir) | `/var/mail/<domain>/<user>/` | Same | rsync (no change) |
| Mail state | `/var/mail-state/` | Same (minus fail2ban/ClamAV) | rsync with excludes |
| DKIM keys | OpenDKIM (`opendkim/keys/`) | Rspamd (`rspamd/dkim/`) | Copy + rename |
| Sieve scripts | `<user>/sieve/` | `<user>/home/sieve/` (v13 change) | Auto-move |
| fail2ban DB | SQLite (v10 schema) | Incompatible (v11 nftables) | Excluded, regenerated |
| ClamAV signatures | Local cache | Re-downloaded | Excluded |
| Accounts | `postfix-accounts.cf` | Same format (bcrypt) | Recreated from variables |
| Aliases | `postfix-virtual.cf` | Same format | Recreated from variables |
| TLS certs | File-based | File-based (manual) | From vault, not migrated |

### Step-by-step procedure

**1. Prepare the source data on the target host:**

```sh
# On the v10 host, stop DMS and copy volumes to the target
ssh v10-host
docker compose down   # or: docker stop mailserver

# Copy to target host
rsync -avz /var/mail/                target:/var/mail-backup/mail/
rsync -avz /var/mail-state/          target:/var/mail-backup/mail-state/
rsync -avz /tmp/docker-mailserver/   target:/var/mail-backup/config/
```

Expected source layout:

```
/var/mail-backup/
├── mail/                  # Maildir (required)
│   └── example.com/
│       ├── user1/
│       │   ├── cur/
│       │   ├── new/
│       │   ├── tmp/
│       │   └── sieve/     # migrated to home/sieve automatically
│       └── user2/
├── mail-state/            # Postfix/Dovecot state (optional)
│   ├── lib-postfix/
│   ├── lib-dovecot/
│   ├── lib-rspamd/
│   ├── lib-fail2ban/      # excluded (incompatible DB schema)
│   └── lib-clamav/        # excluded (re-downloaded at startup)
└── config/                # DMS v10 config (needed for DKIM keys)
    └── opendkim/
        └── keys/
            └── example.com/
                └── mail.private
```

**2. Configure inventory variables:**

```yaml
# host_vars/<host>/main.yml
podman_mailserver_migration_enabled: true
podman_mailserver_migration_source: "/var/mail-backup"
```

Add accounts and aliases to vault — these are **not** imported from v10 config
files, they are recreated from `podman_mailserver_domains`. Verify that bcrypt
password hashes from v10's `postfix-accounts.cf` are copied correctly.

**3. Run the playbook:**

```sh
just ansible-playbook playbooks/03-podman-mailserver.yml
```

The migration tasks run before the containers start (data must be in place first).
On first start, DMS v15 will:

- Upgrade Dovecot internal indexes
- Rebuild Postfix lookup tables
- Initialize Rspamd with migrated DKIM keys
- Create a fresh fail2ban database

**4. Verify:**

```sh
DMS="sudo -u mail-dms XDG_RUNTIME_DIR=/run/user/5200"

# Check container health
$DMS podman pod ps
$DMS podman ps --pod

# Check DMS logs for errors
$DMS podman logs docker-mailserver 2>&1 | tail -50

# Test SMTP
openssl s_client -connect mail.example.com:465 -quiet

# Test IMAP
openssl s_client -connect mail.example.com:993 -quiet

# Check fail2ban status
$DMS podman exec docker-mailserver setup fail2ban status

# Check MTA-STS
curl -sf https://mta-sts.example.com/.well-known/mta-sts.txt

# Check autodiscover
curl -sf https://autoconfig.example.com/mail/config-v1.1.xml
```

**5. Disable migration for subsequent runs:**

```yaml
podman_mailserver_migration_enabled: false
```

### What is NOT migrated

- **Accounts and aliases** — recreated from `podman_mailserver_domains` variables.
  Copy bcrypt hashes from v10's `postfix-accounts.cf` into the vault.
- **TLS certificates** — provided via vault (wildcard Let's Encrypt), not from v10.
- **fail2ban database** — incompatible schema (v10 iptables → v15 nftables).
  Regenerated at first start.
- **ClamAV signatures** — re-downloaded at startup (if enabled).
- **Rspamd learned data** — starts fresh. Bayesian training rebuilds over time.
- **DNS records** — MX, SPF, DKIM (TXT), DMARC, MTA-STS (`_mta-sts` TXT + `mta-sts` A/AAAA),
  autodiscover/autoconfig (A/AAAA). See the DNS records section above for the full list.

### Breaking changes between v10 and v15

Key changes that affect migrated data or behavior:

| Version | Change | Impact |
|---------|--------|--------|
| v11 | fail2ban switched to nftables | Old DB incompatible (excluded) |
| v11 | `PERMIT_DOCKER` default → `none` | Already set in our config |
| v11 | `DMS_DEBUG` → `LOG_LEVEL` | Handled in env template |
| v13 | Sieve scripts moved to `home/sieve` | Auto-migrated by role |
| v13 | DKIM key default 4096 → 2048 bits | Existing keys preserved |
| v13 | `smtps` service → `submissions` | Internal to Postfix |
| v14 | `ONE_DIR` removed | Not used (state volume mounted) |
| v14 | Log format changed (RFC 3339) | Update any external log parsers |
| v14 | Debian 11 → Debian 12 base | Postfix 3.7, OpenSSL 3 |
| v15 | SASLauthd `pam`/`shadow` removed | Not used (file-based accounts) |

## Teardown

The role supports clean removal via `podman_mailserver_state: absent`.

**Keep data** (for migration to K8S or backup):

```sh
just ansible-playbook playbooks/03-podman-mailserver.yml -e podman_mailserver_state=absent
```

This removes: pod, containers, images, Quadlet units, UFW rules, config, TLS.
Mail data (`mail-data/`, `mail-state/`, `mail-log/`) is **preserved**.

**Full purge**:

```sh
just ansible-playbook playbooks/03-podman-mailserver.yml \
  -e podman_mailserver_state=absent \
  -e podman_mailserver_teardown_purge_data=true
```

This additionally removes all mail data, the mailserver home directory, the
`mail-dms` system user, subuid/subgid entries, and lingering.

## Operations

### Inspect containers

All Podman commands must run as the `mail-dms` user:

```sh
sudo -u mail-dms XDG_RUNTIME_DIR=/run/user/5200 podman pod ps
sudo -u mail-dms XDG_RUNTIME_DIR=/run/user/5200 podman ps --pod
sudo -u mail-dms XDG_RUNTIME_DIR=/run/user/5200 podman logs -f docker-mailserver
sudo -u mail-dms XDG_RUNTIME_DIR=/run/user/5200 podman logs -f nginx-mail
sudo -u mail-dms XDG_RUNTIME_DIR=/run/user/5200 podman exec docker-mailserver setup email list
sudo -u mail-dms XDG_RUNTIME_DIR=/run/user/5200 podman exec docker-mailserver setup fail2ban
```

### Restart services

```sh
sudo -u mail-dms XDG_RUNTIME_DIR=/run/user/5200 systemctl --user restart mailserver-pod-pod
sudo -u mail-dms XDG_RUNTIME_DIR=/run/user/5200 systemctl --user restart docker-mailserver
sudo -u mail-dms XDG_RUNTIME_DIR=/run/user/5200 systemctl --user restart nginx-mail
```

### Update DMS version

1. Update `podman_mailserver_version` and `podman_mailserver_digest` in
   `defaults/main.yml` (or override in inventory)
2. Read the [DMS changelog](https://github.com/docker-mailserver/docker-mailserver/blob/master/CHANGELOG.md)
   for breaking changes
3. Re-run the playbook — Quadlet unit change triggers daemon-reload + restart

### Add a new email account

1. Generate bcrypt password hash:
   ```sh
   # Option A — htpasswd (cost 15, recommended)
   ./scripts/bcrypt-password.sh user1
   # Copy the hash after the "user1:" prefix

   # Option B — via the running DMS container
   DMS="sudo -u mail-dms XDG_RUNTIME_DIR=/run/user/5200"
   $DMS podman exec docker-mailserver doveadm pw -s BLF-CRYPT
   # Copy the hash without the {BLF-CRYPT} prefix
   ```
2. Add to `podman_mailserver_domains[].accounts` in vault
3. Re-run the playbook

### DNS records

The role deploys the services but does **not** manage DNS. The following records
must be created manually for each domain.

#### MX + SPF + DMARC

```
example.com.          IN  MX   10 mail.example.com.
example.com.          IN  TXT  "v=spf1 mx a:mail.example.com -all"
_dmarc.example.com.   IN  TXT  "v=DMARC1; p=quarantine; rua=mailto:postmaster@example.com"
```

#### MTA-STS

MTA-STS requires two DNS records per domain plus the HTTPS policy endpoint
(served by the Nginx container at `https://mta-sts.<domain>/.well-known/mta-sts.txt`):

```
_mta-sts.example.com.  IN  TXT  "v=STSv1; id=20260531T120000"
mta-sts.example.com.   IN  A    <server-ip>
mta-sts.example.com.   IN  AAAA <server-ipv6>  (if applicable)
```

The `id` value must be updated every time the policy changes (mode or mx).
Convention: use a timestamp (`YYYYMMDDTHHMMSS`).

Optional SMTP TLS reporting (receives reports about TLS failures):

```
_smtp._tls.example.com.  IN  TXT  "v=TLSRPTv1; rua=mailto:postmaster@example.com"
```

#### Autodiscover / autoconfig

```
autoconfig.example.com.   IN  A     <server-ip>
autodiscover.example.com. IN  A     <server-ip>
autoconfig.example.com.   IN  AAAA  <server-ipv6>  (if applicable)
autodiscover.example.com. IN  AAAA  <server-ipv6>  (if applicable)
```

#### DKIM DNS records

When `dkim_public` is set for a domain, the PEM public key is written to
`config/rspamd/dkim/<domain>.public.txt` for reference. To create the DNS TXT
record from the PEM file:

```sh
# Extract the base64 payload from the PEM (strip headers, join lines)
KEY=$(grep -v '^-' /srv/podman/mailserver/config/rspamd/dkim/example.com.public.txt | tr -d '\n')

# Create the DNS TXT record
echo "mail._domainkey.example.com.  IN  TXT  \"v=DKIM1; k=rsa; p=$KEY\""
```

To generate a new DKIM key pair:

```sh
# Generate 2048-bit RSA key pair
openssl genrsa -out mail.private 2048
openssl rsa -in mail.private -pubout -out mail.public

# dkim_private is the PEM file content (mail.private)
cat mail.private

# dkim_public is the PEM file content (mail.public)
cat mail.public
```

### Transition to Kubernetes (optional)

If you later decide to move to the K8S deployment (`kluctl/mail/mailserver/`):

1. Stop the Podman deployment: `-e podman_mailserver_state=absent` (keeps data)
2. Copy mail data to the K8S node's OpenEBS volume:
   ```sh
   rsync -a /srv/podman/mailserver/mail-data/ <k8s-node>:/var/openebs/local/<pvc>/
   rsync -a /srv/podman/mailserver/mail-state/ <k8s-node>:/var/openebs/local/<pvc>/
   ```
3. Migrate secrets from Ansible Vault to SOPS (`kluctl/targets/<env>.enc.yaml`)
4. Deploy via kluctl: `just deploy-only mail/mailserver`
5. Update DNS records (MX, SPF, etc.) to point to the K8S ingress
6. Optionally purge Podman data: re-run with `podman_mailserver_teardown_purge_data=true`
