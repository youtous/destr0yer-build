# Network Policies — Egress/Ingress Control Design

Last updated: 2026-05-28

## Principle: default-deny + explicit allow per component

All namespaces get `default-deny` (ingress + egress). Each component gets
the minimum egress/ingress required to function. Internet access (`world` entity)
is only granted to components that genuinely need it and cannot use `toFQDNs`.

## Egress matrix

| Component | Namespace | Cluster egress | Internet egress | Notes |
|-----------|-----------|---------------|-----------------|-------|
| Prometheus | observability | all (scrape) | No | cluster entity, cluster-wide |
| Alertmanager | observability | No | host + toFQDNs (SMTP) | SMTP ports only |
| Grafana | observability | No | host:443 (OIDC) | Token exchange via HAProxy |
| Loki | observability | cluster | No | filesystem/S3 backend |
| Gatus | observability | No | host + toFQDNs (checks+SMTP) | Surgical per-domain from args |
| testssl | observability | No | host + toFQDNs (scan targets) | Generated from testssl_hosts |
| Alloy | observability | cluster | No | DaemonSet, reads host logs via hostPath |
| Authelia | authelia | mail ns (SMTP) | host + toFQDNs (SMTP) | Scoped to authelia pod |
| Kyverno | kyverno | cluster | No | Admission webhook, cluster-wide |
| CrowdSec | security | cluster | toFQDNs (hub/API, if CAPI enabled) | Conditional: `enable_crowdsec + crowdsec_enable_capi` |
| Tetragon | security | cluster | No | eBPF, no internet needed |
| cert-manager | cert-manager | cluster (K8S API) | toFQDNs (ACME+DNS provider) | Conditional on `certmanager_issuer_type`, FQDNs in `certmanager_egress_fqdns` |
| Garage | garage | intra-ns | No | S3 API + admin |
| Registry | registry | cluster | toFQDNs (docker.io, ghcr.io, quay.io) | Pull-through cache, port 443 |
| OpenEBS | openebs | cluster | No | Local provisioner, cluster-wide |
| Velero | velero | cluster | No | Reaches Garage S3 via cluster entity |
| HAProxy | haproxy-ingress | cluster | No | Ingress controller, no toPorts (broad) |
| Mailserver | mail | No | world (SMTP ports) | MTA needs any MX — cannot toFQDN. Conditional: `enable_mail` |
| Seafile | seafile | intra-ns + garage:3900 | toFQDNs (PyPI) | pip install boto3 at boot |
| Home Assistant | homeassistant | intra-ns + host | No | OIDC via HAProxy (host:443 todo) |
| Whoami | whoami | No | No | Passive test workload, DNS only |

## Ingress matrix

| Component | Namespace | Allowed from | Ports | Policy |
|-----------|-----------|-------------|-------|--------|
| All app/infra pods | * | HAProxy ingress | all (broad) | `allow-ingress` |
| docker-mailserver | mail | HAProxy ingress | 12525, 10465, 10587, 10993 | `restrict-mail-ingress` |
| docker-mailserver | mail | trusted_cidrs (VPN) | 4190 (ManageSieve) | `restrict-mail-ingress` |
| All pods | * | Prometheus | metrics (broad) | `allow-monitoring` |
| Garage | garage | cluster | 3900-3902 (S3) | `garage-admin-access` |
| Garage | garage | garage ns | 3903 (admin) | `garage-admin-access` |
| Registry | registry | cluster | 5000-5002 | `allow-registry-ingress` |
| Mosquitto | homeassistant | HA + z2m pods | 1883 | `mosquitto-allow` |

## Internet access model

- **toFQDNs** (preferred): cert-manager, CrowdSec, Registry, Seafile, testssl, Gatus — surgical per-domain
- **toEntities: world** (dynamic destinations): DMS only (any MX for mail delivery)
- **toEntities: host** (HAProxy-backed): Grafana (OIDC), HA (OIDC), Alertmanager (SMTP), Authelia (SMTP), Gatus (internal checks)
- **fromCIDR** (VPN-only): ManageSieve 4190 from trusted_cidrs

## Key design decisions

- `docker-mailserver` is **excluded** from the broad `allow-ingress` in mail ns (NotIn matchExpression) to preserve port-level restrictions
- Cilium OR-merges allow rules on the same endpoint — dedicated narrow policies must not be OR'd with broad ones
- `allow-cluster-egress` (cluster entity, no toPorts) is only for namespaces with cluster-wide operators (observability, security, kyverno, openebs, velero, database)
- `toEntities: cluster` without toPorts in `allow-certmanager-cluster` is acceptable: cert-manager manages CRDs across all namespaces

## Dev-specific

Port 1025 (Mailpit) is conditionally included when `smtp_notifier_port == "1025"`.
`certmanager_issuer_type: internal-ca` disables the ACME egress policy entirely.
`crowdsec_enable_capi: false` (default) disables CrowdSec hub egress.
