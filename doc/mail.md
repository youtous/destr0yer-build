# Mail Operations Guide

Last updated: 2026-05-28

## Architecture

```
Internet → Cloud Relay (HAProxy, WireGuard) → K3S HAProxy Ingress → docker-mailserver pod
                                                                     ├── Postfix (SMTP)
                                                                     ├── Dovecot (IMAP, ManageSieve)
                                                                     └── Rspamd (DKIM, SPF, DMARC, spam)
```

| Component | Role |
|-----------|------|
| docker-mailserver 15.1.0 | All-in-one mail (Postfix + Dovecot + Rspamd) |
| Rspamd | DKIM signing, SPF/DMARC verification, spam filtering |
| MTA-STS | nginx serving `/.well-known/mta-sts.txt` per domain |
| Autodiscover | Thunderbird/Outlook autoconfig |
| Parsedmarc | DMARC aggregate report parser (CronJob) |

## Ports and access

| Port | Protocol | Access | Via |
|------|----------|--------|-----|
| 25 | SMTP | Public | Relay → HAProxy → mailserver:12525 (PROXY protocol) |
| 465 | SMTPS | Public | Relay → HAProxy → mailserver:10465 (PROXY protocol) |
| 587 | Submission | Public | Relay → HAProxy → mailserver:10587 (PROXY protocol) |
| 993 | IMAPS | Public | Relay → HAProxy → mailserver:10993 (PROXY protocol) |
| 4190 | ManageSieve | VPN only | HAProxy → mailserver:4190 (trusted_cidrs ACL) |

ManageSieve is restricted at two levels:
1. HAProxy `config-tcp` ACL rejects connections not from `trusted_cidrs`
2. CiliumNetworkPolicy `restrict-mail-ingress` allows port 4190 only from `trusted_cidrs` CIDRs

## Limits

| Setting | Value |
|---------|-------|
| Mailbox size | 1 GB (`POSTFIX_MAILBOX_SIZE_LIMIT: 1073741824`) |
| Message size | 12 MB (`POSTFIX_MESSAGE_SIZE_LIMIT: 12000000`) |
| TLS level | modern (TLS 1.2+ only) |
| Postscreen | enforce |

## Anti-spam stack (Rspamd)

Legacy modules (`OpenDKIM`, `OpenDMARC`, `policyd-spf`, `SpamAssassin`, `Amavis`, `Postgrey`)
are **disabled** — Rspamd handles all of these:

- DKIM signing: per-domain keys via `secrets.mailserver_domains[].dkim_private_b64`
- DKIM verification: built-in Rspamd module
- SPF: built-in Rspamd module
- DMARC: built-in Rspamd module + parsedmarc for reporting
- Spam scoring: Rspamd with Redis (learning enabled)
- Header filtering: `RSPAMD_HFILTER=1` (unknown hostname score: 6)
- Greylisting: disabled (`RSPAMD_GREYLISTING: 0`) — replaced by postscreen

## DNS records (per domain)

Replace `mail.example.com` with your `args.mail_hostname` and `example.com` with the domain.

### Required records

```text
; A/AAAA — NEVER use CNAME on MX domains
example.com.                      IN  A     <relay_public_ip>
example.com.                      IN  AAAA  <relay_public_ipv6>  ; when IPv6 enabled

; MX
example.com.                      IN  MX 10 mail.example.com.

; SPF — start with ~all, then -all after testing
example.com.                      IN  TXT   "v=spf1 mx -all"

; DKIM — use Rspamd-generated public key (selector: mail)
mail._domainkey.example.com.      IN  TXT   "v=DKIM1; k=rsa; p=<PUBLIC_KEY>"

; DMARC — start with p=quarantine, then p=reject after 1 week
_dmarc.example.com.               IN  TXT   "v=DMARC1; p=reject; sp=reject; fo=1; adkim=s; aspf=s; rua=mailto:postmaster+dmarc@example.com; ruf=mailto:postmaster+dmarc-fails@example.com"

; MTA-STS
_mta-sts.example.com.             IN  TXT   "v=STSv1; id=<UNIX_TIMESTAMP>"
mta-sts.example.com.              IN  CNAME <relay_hostname>.

; TLS reporting
_smtp._tls.example.com.           IN  TXT   "v=TLSRPTv1; rua=mailto:postmaster+tls-reports@example.com"
```

### Service discovery (autoconfig)

```text
; Thunderbird autoconfig
autoconfig.example.com.           IN  CNAME <relay_hostname>.

; Outlook autodiscover
autodiscover.example.com.         IN  CNAME <relay_hostname>.

; Mailconf hint
example.com.                      IN  TXT   "mailconf=https://autoconfig.example.com/mail/config-v1.1.xml"

; SRV records (optional, helps clients)
_imaps._tcp.example.com.          IN  SRV   0 0 993 mail.example.com.
_submission._tcp.example.com.     IN  SRV   0 0 465 mail.example.com.
_autodiscover._tcp.example.com.   IN  SRV   0 0 443 autodiscover.example.com.
```

### PTR (reverse DNS)

Set PTR record for the relay public IP to `mail.example.com`. Required for good deliverability.

## MTA-STS deployment

MTA-STS is served by nginx in the `mail` namespace (see `kluctl/mail/mta-sts/`).

Configuration per domain in `secrets.mailserver_domains[]`:
- `mta_sts_mode`: `testing` → `enforce` (after validation)
- `mta_sts_max_age`: `86401` (testing) → `604800` (enforce, 1 week)

Steps:
1. Deploy with `mode: testing`, `max_age: 86401`
2. Set DNS: `_mta-sts.example.com. IN TXT "v=STSv1; id=$(date +%s)"`
3. Validate: https://www.mailhardener.com/tools/mta-sts-validator
4. Wait 1 week, read TLS reports
5. Switch to `mode: enforce`, `max_age: 604800`
6. Update DNS `id=` (increment with `date +%s`)

## DKIM key generation

```bash
# Generate 2048-bit RSA key pair
openssl genrsa -out dkim-private.pem 2048
openssl rsa -in dkim-private.pem -pubout -outform PEM -out dkim-public.pem

# Base64-encode private key for secrets
base64 -w0 dkim-private.pem > dkim-private.b64

# Extract public key for DNS (strip headers, join lines)
grep -v '^-' dkim-public.pem | tr -d '\n'
```

Store the base64-encoded private key in `secrets.mailserver_domains[].dkim_private_b64`.

## Testing

```bash
# SMTP connectivity (from a machine with network access)
swaks -f test@example.com -t recipient@example.com --server mail.example.com:465 -tlsc -a LOGIN

# TLS grade
testssl --starttls smtp mail.example.com:25
testssl mail.example.com:465
testssl mail.example.com:993
```

Testing services:
- https://www.mail-tester.com — deliverability score
- https://en.internet.nl — DKIM/SPF/DMARC/DANE/MTA-STS compliance
- https://mecsa.jrc.ec.europa.eu — EU compliance check
- https://www.mailhardener.com/tools/mta-sts-validator — MTA-STS validation
- https://ssl-config.mozilla.org — TLS configuration reference
- https://bettercrypto.org/#_tls_usage_in_mail_server_protocols — crypto reference

## Patching strategy

DMS 15.1.0 ships Dovecot 2.3.19 (vulnerable to CVE-2026-27857/27858, DoS only).

Mitigations:
1. `user-patches.sh` runs `apt-get upgrade` on every pod start
2. CronJob `mailserver-restart` restarts the pod weekly (Mon 04:00 UTC)
3. Pod memory limits (1024Mi) cap DoS impact
4. Upgrade to DMS v16 (Debian 13 base) when released

## Secrets structure

```yaml
# In SOPS-encrypted target secrets
mailserver_domains:
  - domain: example.com
    mta_sts_mode: enforce
    mta_sts_max_age: 604800
    dkim_private_b64: "<base64-encoded RSA private key>"
    parsedmarc_user: dmarc
    parsedmarc_password: "<password>"
    accounts:
      - username: user
        bcrypt_password: "<bcrypt hash>"
        quota_mb: 1024
    aliases:
      - alias: "alias@example.com"
        to: "user@example.com"
    receive_bans: []
    send_bans: []
```
