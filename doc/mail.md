# Mail Operations Guide

Last updated: 2026-06-03

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
| TLS ciphers | `HIGH:@SECLEVEL=2` (see below) |
| Postscreen | enforce |

### TLS hardening — cipher and signature policy

```text
# postfix-main.cf
tls_high_cipherlist = HIGH:@SECLEVEL=2
smtp_tls_ciphers = high
smtpd_tls_ciphers = high
tls_preempt_cipherlist = yes
tls_ssl_options = NO_COMPRESSION, NO_RENEGOTIATION
```

**Why no explicit `tls_exclude_ciphers`**: OpenSSL 3.x `HIGH` cipher list
already excludes all genuinely broken ciphers (NULL, EXPORT, DES, RC4, MD5).
An explicit exclude list is redundant and risks breaking deliverability.

**HMAC-SHA1 cipher MACs** (e.g. `ECDHE-RSA-AES256-SHA`) are deliberately kept.
HMAC-SHA1 is not broken — SHA-1 collision weaknesses do not affect HMAC
(RFC 2104). Excluding them would force old MTAs to fall back to plaintext
(`smtpd_tls_security_level = may` = opportunistic TLS), which is strictly worse.

**`@SECLEVEL=2`** (112-bit minimum security) solves a different problem flagged
by internet.nl: the **signature algorithm** used during TLS 1.2 key exchange.
By default, OpenSSL offers SHA-1 as a hash for the server's digital signature
of key exchange parameters. NCSC-NL
([guidelines v2025-05, §3.3.5](https://english.ncsc.nl/publications/publications/2021/january/19/it-security-guidelines-for-transport-layer-security-2.1))
rates SHA-1 for signatures as "insufficient".

`@SECLEVEL=2` in the cipher string:

| What it does | Impact |
|-------------|--------|
| Disables SHA-1 as **signature algorithm** for key exchange | Fixes internet.nl finding |
| Keeps HMAC-SHA1 as **cipher MAC** | No deliverability impact (HMAC-SHA1 ≥ 112-bit) |
| Requires RSA ≥ 2048 bits | Our cert is 2048 — OK |
| Requires DH ≥ 2048 bits | Postfix auto-generates — OK |

This is a global setting (`tls_high_cipherlist` is shared between `smtpd` and
`smtp`). Outbound connections to servers with < 2048-bit certs fall back to
plaintext (same behavior as any cipher negotiation failure with `may`).

| Hash for key exchange signature | Status (NCSC-NL) |
|---------------------------------|-------------------|
| SHA-256, SHA-384, SHA-512 | Good |
| SHA-224 | Phase out |
| **SHA-1**, MD5 | Insufficient — disabled by `@SECLEVEL=2` |

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

### DANE/TLSA (requires DNSSEC)

DANE ([RFC 7672](https://datatracker.ietf.org/doc/html/rfc7672)) binds a mail
server's TLS certificate to a DNSSEC-signed DNS record, eliminating reliance on
certificate authorities for SMTP. internet.nl scores DANE as a key compliance
item.

**Prerequisites**:
1. Domain zone signed with DNSSEC (DS record at registrar)
2. MX hostname zone also signed (if different from domain zone)
3. DNSSEC-validating resolver on the mail server (dnscrypt-proxy handles this)

**TLSA record** — use `3 1 1` (DANE-EE, SPKI, SHA-256) as recommended by
RFC 7672 section 3.1:

```text
; Generate the TLSA hash from your certificate's public key
openssl x509 -in cert.pem -noout -pubkey \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 -binary \
  | xxd -p -c 256

; Publish for each mail port (25 is required, 465/993 recommended)
_25._tcp.mail.example.com.   IN  TLSA  3 1 1 <hex-hash>
_465._tcp.mail.example.com.  IN  TLSA  3 1 1 <hex-hash>
_993._tcp.mail.example.com.  IN  TLSA  3 1 1 <hex-hash>
```

**Why `3 1 1`** (SPKI selector): The hash depends only on the public key, not
certificate metadata (issuer, expiry). This survives Let's Encrypt renewals
as long as the private key is reused. For 90-day renewal cycles, this is the
difference between hands-off automation and updating DNS every 3 months.

**Let's Encrypt + DANE — key reuse strategy**:

| Method | How | TLSA update needed? |
|--------|-----|-------------------|
| `certbot --reuse-key` | Keeps the same private key across renewals | No (SPKI hash unchanged) |
| `lego --reuse-key` | Same, for non-K3S hosts | No |
| cert-manager `privateKey.rotationPolicy: Never` | K8S: keeps key in Certificate spec | No |
| Key rotation (manual) | Generate new key, update TLSA before renewal | Yes — publish new TLSA, wait for DNS propagation, then rotate |

**Key rotation with DANE** — when you must rotate the private key:
1. Generate new key pair
2. Compute new TLSA hash
3. Publish **both** old and new TLSA records (dual records)
4. Wait for DNS propagation (≥ 2x TTL)
5. Deploy new certificate with new key
6. Remove old TLSA record after TTL expiry

**DANE + MTA-STS — complementary, not competing**:

| | DANE | MTA-STS |
|---|------|---------|
| **Trust anchor** | DNSSEC (no CA needed) | CA-signed HTTPS certificate |
| **Requires** | DNSSEC on domain | HTTPS endpoint for policy file |
| **Adoption** | ~30% of MX hosts validate DANE | Wider client support |
| **Failure mode** | Hard fail if TLSA present but invalid | Configurable (testing/enforce) |
| **Recommendation** | Deploy both — DANE for DNSSEC-aware MTAs, MTA-STS for the rest |

**Postfix outbound DANE** — verify TLSA records when sending:

```text
# Add to postfix-main.cf for outbound DANE verification
smtp_dns_support_level = dnssec
smtp_tls_security_level = dane
```

With `dane` security level, Postfix:
- Uses mandatory TLS when TLSA records are found and valid
- Falls back to opportunistic TLS when no TLSA records exist
- Rejects delivery if TLSA records exist but are unusable (no silent downgrade)

This is safe to enable even before publishing your own TLSA records — it only
affects outbound verification of other servers' DANE.

**Validation**:

```bash
# Verify your TLSA record
dig +dnssec TLSA _25._tcp.mail.example.com

# Verify DNSSEC chain
dig +dnssec +cd mail.example.com

# Test DANE end-to-end
# internet.nl → "Test your email" → checks DANE automatically
# Or: https://dane.sys4.de (DANE SMTP validator)
# Or: https://www.huque.com/bin/danecheck (TLSA record checker)
```

**Implementation status**: TODO — requires DNSSEC on domain (deSEC supports
DNSSEC natively). Blocked until prod DNS setup (see ADR-024).

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

## Testing and validation

### Quick connectivity check

```bash
# SMTP connectivity (from a machine with network access)
swaks -f test@example.com -t recipient@example.com --server mail.example.com:465 -tlsc -a LOGIN

# IMAP connectivity
openssl s_client -connect mail.example.com:993
```

### TLS audit with testssl.sh

[testssl.sh](https://github.com/drwetter/testssl.sh) audits TLS configuration,
cipher suites, protocols, certificate chain, and known vulnerabilities.

```bash
# SMTP STARTTLS (port 25)
testssl --starttls smtp mail.example.com:25

# SMTPS (port 465)
testssl mail.example.com:465

# IMAPS (port 993)
testssl mail.example.com:993

# All ports, JSON output for archiving
testssl --jsonfile results.json --starttls smtp mail.example.com:25
testssl --jsonfile results.json --append mail.example.com:465
testssl --jsonfile results.json --append mail.example.com:993
```

Expected results with `TLS_LEVEL=modern` + `@SECLEVEL=2`:
- No SSLv2/SSLv3/TLSv1.0/TLSv1.1
- Only TLSv1.2 and TLSv1.3
- No RC4, DES, 3DES, NULL, EXPORT ciphers
- No SHA-1 for key exchange signatures (SECLEVEL=2)
- Forward secrecy (ECDHE) on all cipher suites
- Valid certificate chain with trusted CA

A weekly automated testssl CronJob runs in the cluster
(`kluctl/observability/testssl/`) and sends HTML reports by email.

### internet.nl compliance check

[internet.nl](https://internet.nl) is the Dutch Internet Standards Platform's
free compliance checker. It validates the full email security stack in one pass.

Go to https://internet.nl → **Test your email** → enter your domain.

It checks:

| Category | What it tests |
|----------|-------------|
| **STARTTLS** | TLS availability, version, cipher order, DANE |
| **DANE** | TLSA records in DNS (optional but recommended) |
| **SPF** | Syntax, strictness (`-all` vs `~all`) |
| **DKIM** | Selector, key size, algorithm |
| **DMARC** | Policy (`reject`), alignment (`strict`), reporting URIs |
| **MTA-STS** | Policy file, DNS TXT record, mode (`enforce`) |
| **TLS-RPT** | TLS reporting record in DNS |

Target: **100% score**. Common deductions:
- DANE not configured → add TLSA records (requires DNSSEC on domain)
- DMARC `p=quarantine` instead of `p=reject` → switch after validation period
- SPF `~all` instead of `-all` → switch after confirming no missing senders

### Additional testing services

| Service | What it checks | URL |
|---------|---------------|-----|
| mail-tester.com | Deliverability score (send an email to their address) | https://www.mail-tester.com |
| MX Toolbox | MX, DNS, blacklist, SMTP diagnostics | https://mxtoolbox.com |
| MECSA | EU email compliance (TLS, DANE, SPF, DKIM, DMARC) | https://mecsa.jrc.ec.europa.eu |
| Mailhardener | MTA-STS validator, DMARC analyzer | https://www.mailhardener.com/tools/mta-sts-validator |
| Hardenize | Full domain security audit (HTTPS + email) | https://www.hardenize.com |
| CheckTLS | SMTP TLS negotiation tester | https://www.checktls.com |

### Reference guides

| Guide | Scope |
|-------|-------|
| [Mozilla SSL Configuration Generator](https://ssl-config.mozilla.org) | TLS cipher/protocol recommendations (Postfix preset) |
| [BetterCrypto — Applied Crypto Hardening](https://bettercrypto.org/#_tls_usage_in_mail_server_protocols) | Mail server crypto configuration reference |
| [M3AAWG Best Practices](https://www.m3aawg.org/published-documents) | Industry messaging anti-abuse best practices |
| [RFC 8461 — MTA-STS](https://datatracker.ietf.org/doc/html/rfc8461) | MTA-STS specification |
| [RFC 8460 — TLS-RPT](https://datatracker.ietf.org/doc/html/rfc8460) | TLS reporting specification |

## Security checklist

Pre-production validation — run through before exposing a mail server to the
internet. Items marked with automated tooling can be verified via
testssl.sh / internet.nl.

### Transport security

- [ ] TLS 1.2+ only — no SSLv2/SSLv3/TLSv1.0/TLSv1.1 (`TLS_LEVEL=modern`)
- [ ] Cipher level `HIGH:@SECLEVEL=2` (excludes broken ciphers + SHA-1 for signatures)
- [ ] Forward secrecy — ECDHE on all suites
- [ ] Certificate valid, not self-signed, full chain served
- [ ] STARTTLS on port 25 (opportunistic for receiving)
- [ ] Implicit TLS on 465 (submission) and 993 (IMAP)
- [ ] testssl.sh shows no CRITICAL or HIGH findings

### DANE and DNSSEC (internet.nl requirements)

- [ ] Domain zone signed with DNSSEC (DS record at registrar)
- [ ] MX hostname zone signed with DNSSEC
- [ ] TLSA `3 1 1` records published for ports 25, 465, 993
- [ ] TLSA hash matches current certificate public key
- [ ] Outbound DANE enabled (`smtp_dns_support_level = dnssec`, `smtp_tls_security_level = dane`)
- [ ] Key reuse configured for automated renewals (`--reuse-key` or `rotationPolicy: Never`)
- [ ] DANE + MTA-STS both deployed (complementary coverage)
- [ ] CAA record restricting issuance to Let's Encrypt

### Authentication and anti-spoofing

- [ ] SPF: `v=spf1 mx -all` (hard fail)
- [ ] DKIM: RSA 2048-bit, selector published, signing verified
- [ ] DMARC: `p=reject; sp=reject; adkim=s; aspf=s` (strict alignment)
- [ ] MTA-STS: `mode: enforce`, `max_age: 604800`
- [ ] TLS-RPT: `_smtp._tls` TXT record with rua
- [ ] SPOOF_PROTECTION enabled (DMS)
- [ ] PTR record matches HELO hostname
- [ ] No open relay (`PERMIT_DOCKER=none`, SASL required for submission)

### Spam and abuse prevention

- [ ] Postscreen with DNSBL enforcement
- [ ] Rspamd scoring enabled (HFILTER score ≥ 6 for unknown hostnames)
- [ ] fail2ban / CrowdSec active
- [ ] Rate limiting on submission ports
- [ ] Message size limit configured

### Monitoring

- [ ] testssl.sh CronJob (weekly, email report)
- [ ] Parsedmarc for DMARC aggregate reports
- [ ] Log shipping to Loki (Postfix, Dovecot, Rspamd)
- [ ] Alerting on delivery failures, queue growth, auth failures

### internet.nl 100% score — full checklist

internet.nl tests 7 categories. Map to our implementation:

| Category | What they check | Our implementation | Status |
|----------|----------------|-------------------|--------|
| **STARTTLS** | TLS available, TLS 1.2+, cipher order, no SSLv3, no SHA-1 for key exchange signatures | `TLS_LEVEL=modern`, `HIGH:@SECLEVEL=2` | ✅ |
| **Certificate** | Valid, not expired, full chain, matches hostname | cert-manager / Let's Encrypt wildcard | ✅ (prod) |
| **DANE** | DNSSEC + TLSA `3 1 1` for port 25 | deSEC supports DNSSEC | ⏳ TODO |
| **SPF** | `v=spf1 ... -all` (hard fail) | Configured per domain | ✅ |
| **DKIM** | Selector published, RSA ≥ 2048 bits, signing verified | Rspamd, 2048-bit RSA, selector `mail` | ✅ |
| **DMARC** | `p=reject`, strict alignment, reporting URIs | `adkim=s; aspf=s; p=reject` | ✅ |
| **MTA-STS** | Policy file served, `mode: enforce`, TLS-RPT record | nginx + `_smtp._tls` TXT | ✅ |

Missing for 100%: DANE (requires DNSSEC activation on domain via deSEC).

### Periodic re-validation

| Frequency | Action |
|-----------|--------|
| Weekly | testssl.sh automated report (CronJob) |
| Monthly | internet.nl full compliance check (manual) |
| On change | Re-run after any TLS, DNS, or Postfix config change |
| Quarterly | Review DMARC aggregate reports (parsedmarc) |

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
