# ADR-034: DMS v10 to v15 mail migration on new infrastructure

**Status**: WIP — to be executed during production deployment

**Date**: 2026-05-26

**Scope**: Migration of the Postfix + Dovecot mail service operated via
Docker Mailserver (DMS)

## Context

The current mail infrastructure runs Docker Mailserver v10 with Postfix and
Dovecot. The planned migration includes both an infrastructure change and a major
version jump to DMS v15, which rules out a simple technical duplication of the
existing setup.

The primary goal is to minimize functional changes for users while reducing
operational risk. The service will be migrated with an assumed outage during the
final synchronization to prevent any data divergence between source and target.

Mail data consists primarily of Dovecot mailboxes and Postfix state. User data
compatibility is generally achievable via a faithful Maildir copy, but the DMS
configuration itself cannot be assumed compatible between v10 and v15 without
explicit review.

## Decision

The mail service will be migrated using a **side-by-side** strategy to new
infrastructure, treating DMS v15 as a **fresh installation** rather than a direct
clone of DMS v10.

User mail data will be migrated via **`rsync` over SSH** after one or more
pre-synchronizations, followed by a final sync performed once Postfix and Dovecot
are stopped on the source, to prevent any data divergence. The target will not be
exposed to users in production before this final synchronization and functional
validation.

The DMS configuration will not be copied wholesale from v10. The DMS v15 stack will
be rebuilt cleanly from the target version's documentation and conventions, then
enriched only with still-relevant configuration elements such as accounts, aliases,
DKIM, certificates, Sieve rules, and compatible overrides.

The target infrastructure will use persistent storage decoupled from the instance or
node lifecycle, to simplify future migrations, host replacements, and maintenance
operations.

## Detailed sequence

1. Lower DNS TTLs for affected records (MX and mail infrastructure records) before
   migration to accelerate failover propagation.
2. Prepare a new target instance or node with DMS v15, Postfix and Dovecot in their
   compatible versions for this release, without blindly reusing the old DMS v10
   configuration.
3. Rebuild the target configuration from DMS v15 conventions, importing only
   still-valid parameters.
4. Perform one or more preparatory `rsync` runs for mail data.
5. Test the target on pilot accounts or in a non-exposed mode, without general
   production access to migrated mailboxes.
6. On cutover day, stop Postfix and Dovecot on the source.
7. Run a final `rsync` with strict file metadata preservation.
8. Switch DNS/MX records.
9. Start the target and validate inbound SMTP, outbound SMTP, IMAP,
   authentication, queues, and mailbox integrity.
10. Keep the old platform offline but available for controlled rollback during the
    observation period.

## Migration command

The recommended base command for Maildir data:

```bash
rsync -aHAX --numeric-ids --delete \
  -e ssh old:/var/mail/ /var/mail/
```

This approach is chosen because `rsync` enables efficient incremental migration and
preserves permissions, hard links, ACLs, extended attributes, and numeric IDs —
suitable for a faithful filesystem-level mail data copy. It does not exempt from
functional Dovecot-side verification for IMAP and POP3.

## Data compatibility

**Mailbox data** is considered broadly compatible if stored in Maildir format and
copied faithfully, preserving flags, UIDs, UIDVALIDITY, subscriptions, and where
applicable UIDL for POP3. However, the **full DMS configuration** is not considered
directly compatible between v10 and v15 due to breaking changes introduced in
intermediate versions.

## Alternatives considered

### In-place upgrade from DMS v10 to v15

Rejected because it combines infrastructure change and multiple major DMS version
jumps into a single operation. This greatly increases the risk of hard-to-diagnose
failures and complicates rollback.

### Mailbox migration with `doveadm backup` or `doveadm sync`

Considered technically sound from a Dovecot perspective, since `doveadm` handles
IMAP and POP3 semantics beyond simple file copying. Not retained as the primary
method because the chosen operational strategy imposes a clean service cutover at
final sync time and favors the simplicity of a filesystem-level transfer in the
current context.

### Full clone of the old DMS tree

Rejected because DMS v15 introduces structural and behavioral changes that make raw
reuse of v10 configuration and state risky.

## Consequences

This decision simplifies rollback since the old platform remains intact until the
new one is validated. It also reduces coupling between the mail platform and the
execution host, and allows starting from a clean DMS v15 base that is more
maintainable long-term.

In exchange, this strategy requires explicit configuration review and
reconstruction work. It also mandates thorough functional acceptance testing, since
`rsync` guarantees file copying but does not alone validate protocol transparency
for IMAP and POP3 clients.

## Validation checklist

Before final validation, the following checks must be performed:
- SMTP and IMAP authentication
- inbound SMTP reception
- outbound SMTP sending
- Maildir integrity
- IMAP folder, flag, and subscription preservation
- POP3 UIDL verification (if still in use)
- DKIM, SPF, and DMARC verification
- Postfix queue verification
- TLS certificate verification
- verification of ancillary jobs including `getmail` if present
