# ADR-033: Mail architecture — dual-cluster with backup MX and whitehole NAT

**Status**: Proposed

**Context**: The goal is to operate a mail service across two independent Kubernetes
clusters without exposing them directly to the Internet. Public exposure is handled
by two distinct "whiteholes" acting as NAT entry points to the clusters.

The architecture must address the following requirements:
- SMTP reception continuity when the primary cluster is unavailable;
- clear separation between the SMTP plane and the IMAP/mailbox storage plane;
- disaster recovery based on automated Kubernetes backups to S3;
- no shared write-access mail storage between the two clusters;
- explicit DNS and certificate management for the mail domain;
- reasonable protection of the backup MX queue without introducing pseudo-active/active inter-cluster replication.

Key clarification: the secondary cluster is not intended to run Dovecot permanently.
During normal operation it serves only as a backup MX Postfix and does not host
active mailboxes.

**Decision**: The architecture uses two distinct public whiteholes, two MX records,
and a strict role separation:
- cluster A: nominal service running Postfix + Dovecot;
- cluster B: backup MX running Postfix only during normal operation;
- Dovecot on cluster B: not deployed in nominal mode, restored and deployed only
  in a disaster recovery scenario;
- Kubernetes backups scheduled every 6 hours to an S3-compatible backend;
- Garage S3 used as the object backend for Velero backups and, depending on the
  storage engine, for OpenEBS backup exports/snapshots — but not as live mailbox
  storage.

This decision favors operational simplicity for the secondary and avoids turning the
standby cluster into a pseudo-active/active replica of the IMAP stack. A backup MX
does not need mailboxes or IMAP to ensure SMTP reception continuity: it accepts,
queues, and relays to the primary as soon as it becomes reachable again.

## Architecture

### Public exposure

DNS publishes two distinct MX hosts with different priorities. Sending servers try
the highest-priority MX first, then fall back to the second if the first is
unavailable.

The mapping is:
- `MX 10 -> mx1.example.tld -> whitehole-1 -> NAT -> cluster A`;
- `MX 20 -> mx2.example.tld -> whitehole-2 -> NAT -> cluster B`.

This approach aligns network behavior with standard SMTP behavior. It avoids a
single front-end that would need to dynamically decide which cluster to route to
while becoming a single point of failure and diagnosis.

### Cluster A — nominal service

Cluster A hosts the full mail service:
- Postfix for inbound and outbound SMTP;
- Dovecot for IMAP and mailbox access;
- persistent storage for queues and mail data;
- complete production mail domain configuration.

Whitehole-1 only performs NAT translation to the services exposed by cluster A.
Since Postfix is behind NAT, its configuration must account for the external
address seen from the Internet, notably via `proxy_interfaces` when needed.

### Cluster B — nominal backup MX

Cluster B runs only a minimal standby Postfix during normal operation. Its role
is to accept mail for authorized domains, store it in its persistent queue, and
relay it to cluster A once the primary becomes available again.

During normal operation, Dovecot is not deployed on this cluster. Cluster B
therefore does not expose IMAP and does not contain production-mounted mailboxes.

For the backup MX, Postfix must be explicitly configured with:
- `relay_domains` for accepted domains;
- `transport_maps` or an equivalent route to relay to the primary server;
- `relay_recipient_maps` if recipient validation is implemented to avoid
  backscatter.

Whitehole-2 performs NAT to this standby Postfix. As with the primary,
`proxy_interfaces` must reflect the public address carried by this NAT front-end
to avoid inconsistent behavior when the primary is unreachable.

## Secondary Postfix queue protection

Backup MX protection should not be thought of as application-level Postfix
replication between clusters. The critical data to protect is the local persistent
queue of the secondary Postfix, not an active/active state of two standby
instances.

Cluster B must therefore store the Postfix queue on a durable persistent volume
replicated **within cluster B**. This intra-cluster replication is handled by the
chosen Kubernetes storage engine, not by sharing the queue between clusters A and B.

This approach reduces the risk of message loss if a node or disk fails in the
secondary cluster. However, it does not protect against total loss of cluster B
before messages are relayed to the primary; this residual risk is inherent to a
single backup MX.

Additionally, the backup MX configuration must be synchronized via GitOps or
equivalent to ensure consistency of `relay_domains`, `transport_maps`, and
optionally `relay_recipient_maps` with the primary cluster.

## OpenEBS and Garage S3

OpenEBS distinguishes local/replicated volumes from the backup and restore plane.
Its documentation indicates that OpenEBS volume backup and restore works with
Velero and that data can be backed up to object targets such as AWS S3, GCP Object
Storage, or MinIO; local OpenEBS volumes can also be backed up and restored via
Velero to any S3-compatible storage.

Garage S3 can therefore be used as an S3-compatible object backend for:
- Velero backups of the mail namespace;
- OpenEBS volume backups/restores depending on the engine and plugin chosen;
- incremental snapshots/exports if the chosen OpenEBS engine supports them in this
  mode.

However, Garage S3 must not be interpreted as a shared live storage backend for
Postfix or Dovecot. It serves as an object backend for backup/restore, not as a
simultaneous RW filesystem for mailboxes or the SMTP queue.

Practical consequence:
- OpenEBS provides persistence and local PVC replication within a cluster;
- Garage S3 provides the object backend for backups;
- Velero orchestrates backup and restore of Kubernetes resources and volumes using
  the supported method.

## Dovecot role

Dovecot is **never** deployed on the standby cluster during normal operation.
Cluster B is not a hot IMAP replica — it is a standby SMTP reception site.

Dovecot's role on cluster B only exists in a disaster recovery scenario. In that
case, the service is restored and deployed after recovering Kubernetes backups and
the necessary volumes.

This choice has several positive effects:
- reduced complexity on cluster B;
- no false need for cross-cluster shared storage for mailboxes;
- clear failure semantics: reception continuity on one side, mailbox recovery on
  the other.

## DNS and cert-manager

Mail service DNS management must be separated from certificate management. The
`A/AAAA`, `MX`, and optional `PTR`, `SPF`, `DKIM`, and `DMARC` records belong to
the domain's authoritative DNS and must be managed by the DNS provider or the
chosen infrastructure-as-code tool.

Cert-manager must not be considered the manager of mail server business DNS. Its
role is to automate certificate issuance, renewal, and storage in Kubernetes; during
a DNS-01 challenge it creates the necessary TXT validation records, but this does
not replace administration of MX records and public hosts.

The responsibility split is therefore:
- mail DNS: managed outside the cluster, ideally via GitOps/IaC;
- TLS certificates: managed by cert-manager within each cluster;
- ACME validation: performed by cert-manager via DNS-01 when needed.

In this architecture, public DNS publishes:
- `mx1.example.tld -> whitehole-1 public IP`;
- `mx2.example.tld -> whitehole-2 public IP`;
- `example.tld MX 10 mx1.example.tld`;
- `example.tld MX 20 mx2.example.tld`.

Certificates needed for SMTP/Submission/IMAP services exposed by cluster A, and
eventually by cluster B during a DR promotion, are issued and renewed via
cert-manager in the respective clusters.

## Backup and disaster recovery

The backup strategy relies on Velero with automated scheduling. Velero supports
cron-based schedules, allowing a backup every 6 hours with an expression like
`0 */6 * * *`.

Backups must cover:
- the complete mail namespace;
- associated Kubernetes manifests;
- PVCs/PVs needed for Postfix and Dovecot;
- Secrets, ConfigMaps, certificates, and network objects;
- data exported to Garage S3 or another S3-compatible backend for restore on
  cluster B.

This strategy provides disaster recovery, not active/active IMAP high availability.
The nominal RPO depends on backup frequency — up to 6 hours here if no additional
application-level replication is added.

## Failover sequence

### Primary incident without DR promotion

If cluster A goes down but the DR plan is not activated, remote servers eventually
use `MX 20`. Cluster B then receives mail, holds it in the Postfix queue, and
periodically attempts to relay it to cluster A until it comes back.

In this scenario, users cannot retrieve their mail via IMAP on the secondary site.
IMAP service remains unavailable until cluster A is restored or a DR promotion is
decided.

### DR promotion on cluster B

If cluster A unavailability is prolonged, cluster B is promoted to standby primary.
This promotion follows these steps:
1. Velero restore of the latest consistent backup from Garage S3;
2. recreation of PVCs/PVs and necessary Kubernetes objects;
3. deployment of Dovecot on cluster B;
4. validation of SMTP and IMAP operation;
5. optional routing and operations update to treat B as temporary primary.

## Consequences

### Advantages

- SMTP reception continuity without exposing clusters directly to the Internet;
- design compatible with standard MX behavior;
- very simple secondary cluster in nominal mode, limited to Postfix and its
  persistent queue;
- Dovecot absent from the standby site unless DR is triggered;
- clear separation between live OpenEBS storage and Garage S3 object backend for
  backups.

### Disadvantages

- no IMAP available on cluster B in nominal mode;
- mailbox recovery is not instant — conditioned on a DR restore;
- non-zero RPO, tied to backup frequency;
- requires a dedicated DR promotion runbook to transform cluster B into a full site;
- residual risk of losing mail in the backup MX queue if cluster B is lost before
  relay.

## Alternatives considered

### Single whitehole in front of both clusters

Rejected because it re-centralizes routing to a single front-end and blurs the
correspondence between MX records and actual backends. Two distinct whiteholes are
simpler to diagnose, more consistent with MX DNS, and easier to evolve
independently.

### Dovecot deployed permanently on cluster B

Rejected because it adds unnecessary IMAP complexity for a cluster that only serves
as a backup MX in nominal mode. Without a dedicated application-level replication
strategy, it provides no clear benefit over on-demand DR restore.

### Garage S3 as live mail storage

Rejected because the documented role of S3-compatible backends in this architecture
is as an object target for backup/restore, not as a live RW volume for mailboxes
and SMTP queues.

## Operational recommendations

- Publish two public MX records with distinct priorities, each pointing to a
  different whitehole.
- Deploy Postfix + Dovecot only on cluster A in nominal mode.
- Deploy only backup MX Postfix on cluster B in nominal mode.
- Store the backup MX queue on a protected OpenEBS PVC replicated within cluster B.
- Use Garage S3 as the S3-compatible object backend for Velero and compatible
  OpenEBS backup mechanisms.
- Configure `proxy_interfaces` on both Postfix instances to reflect the external
  addresses exposed by the whitehole NATs.
- Manage mail business DNS outside cert-manager, ideally via GitOps/IaC; use
  cert-manager only for certificates and ACME challenges.
- Schedule Velero backups every 6 hours with retention and regular restore tests.
- Document a DR runbook explaining Dovecot deployment on B only during a standby
  promotion.

## Design summary

The secondary cluster does not run Dovecot permanently. During normal operation it
serves only as a backup MX Postfix behind its dedicated whitehole; its queue is
protected by persistent storage replicated within cluster B, while Garage S3 serves
as the object backend for Velero/OpenEBS backups. Dovecot is restored and deployed
on this cluster only upon an explicitly decided DR failover, and mail service DNS
remains managed outside cert-manager.
