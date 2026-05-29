# Kluctl Deployment

Kubernetes-level declarative deployments managed by [Kluctl](https://kluctl.io/).

## Structure

```
kluctl/
├── .kluctl.yaml              # Project config: targets + shared arg defaults
├── deployment.yaml           # Root deployment: vars loading + component ordering
├── targets/
│   ├── defaults.yaml         # Derived args (domains, emails from cluster_domain)
│   ├── dev.enc.yaml          # SOPS-encrypted secrets (dev)
│   └── secrets-reference.yaml # How to generate each secret
├── namespaces/               # Namespace creation + smtp-notifier Secret
├── namespaces-rbac/          # RBAC for kluctl operator
├── security/                 # cert-manager, kyverno, crowdsec, tetragon, reloader, network-policies
├── storage/                  # openebs, garage, registry (pull-through cache), velero
├── database/                 # mariadb-operator
├── ingress/                  # haproxy-ingress (DaemonSet, hostNetwork, TCP mail)
├── authelia/                 # SSO / OIDC provider
├── observability/            # prometheus+grafana, loki, alloy, gatus, ntfy, testssl, drift-detection
├── whoami/                   # Health check / auth test service
├── mail/                     # docker-mailserver, mta-sts, autodiscover, parsedmarc
├── home/                     # home-assistant, mosquitto, zigbee2mqtt
└── apps/
    └── seafile/              # File sync (Garage S3 + MariaDB + Authelia OIDC)
```

## How it works

### Configuration layers

```
.kluctl.yaml args (static defaults)    ← prod-ready: Enforce, S3, Let's Encrypt, TLS SMTP
        ↓ overridden by
target args (per-env)                   ← dev: Audit, filesystem, short retention, no TLS
        ↓ merged with
targets/defaults.yaml (vars)            ← derived values: domains, emails from cluster_domain
        ↓ merged with
targets/<env>.enc.yaml (SOPS secrets)   ← credentials, API keys, private keys
```

Templates access all values via `{{ args.X }}` or `{{ secrets.X }}`.

### Deploy order

Components deploy in phases separated by barriers:

1. **Namespaces** — create all namespaces, deploy smtp-notifier Secret
2. **Security + RBAC** — cert-manager, kyverno, crowdsec, tetragon, network-policies
3. **Infrastructure** — storage (openebs, garage, registry, velero), database, ingress, authelia
4. **Applications** — observability, whoami, mail, home, seafile

Barriers ensure dependencies are ready before dependents deploy.

### Component toggles

Each optional component is controlled by an arg:

| Arg | Default | Controls |
|-----|---------|----------|
| `enable_authelia` | true | Authelia SSO |
| `enable_mail` | true | Mailserver + MTA-STS + parsedmarc |
| `enable_homeassistant` | true | Home Assistant + MQTT + Zigbee2MQTT |
| `enable_whoami` | true | Whoami test service |
| `enable_seafile` | true | Seafile file sync |
| `enable_crowdsec` | true | CrowdSec LAPI + agents |
| `crowdsec_online_api` | true | CrowdSec community blocklist + console (off in dev) |
| `enable_ntfy` | false | ntfy push notifications |

Set to `false` in target args to skip deployment.

## Adding a new environment

1. Add a target in `.kluctl.yaml`:

```yaml
targets:
  - name: home-1
    context: home-1-cluster
    args:
      environment: home-1
      cluster_domain: example.com
      # Only override what differs from defaults
      trusted_cidrs:
        - "10.0.0.0/24"
        - "10.42.0.0/16"
        - "10.43.0.0/16"
```

2. Create SOPS secrets file:

```sh
cp targets/dev.enc.yaml targets/home-1.enc.yaml
# Edit with real values (encrypts on save):
just sops-edit kluctl/targets/home-1.enc.yaml
```

3. Deploy:

```sh
kluctl deploy -t home-1
```

All prod-ready defaults apply automatically (Kyverno Enforce, S3 storage,
Let's Encrypt TLS, authenticated SMTP).

## Common commands

```sh
just deploy                           # Deploy all (via Ansible wrapper)
just deploy-only security/kyverno     # Single component
just diff                             # Preview changes without applying
just prune                            # Remove orphaned resources
just render                           # Offline template validation

# Direct kluctl (without just wrapper — requires SOPS_AGE_KEY_FILE in env, see .env):
kluctl deploy -t dev --project-dir kluctl/
kluctl render -t dev --project-dir kluctl/ --offline-kubernetes --kubernetes-version 1.36
```

## Secrets

All secrets are SOPS-encrypted in `targets/<env>.enc.yaml` using age keys.
See `targets/secrets-reference.yaml` for generation commands for each secret.

The SOPS age key is never stored in the repo. It is deployed temporarily
during `just deploy` (auto-removed after 30 minutes).

## Arg reference

Defaults are in `.kluctl.yaml` (static, prod-ready).
Derived values are in `targets/defaults.yaml` (templated from `cluster_domain`).
Per-env overrides are in `.kluctl.yaml` target args.

### Key args

| Arg | Prod default | Dev override | Purpose |
|-----|-------------|--------------|---------|
| `kyverno_validation_action` | Enforce | Audit | Policy enforcement mode |
| `certmanager_issuer_type` | letsencrypt | internal-ca | TLS certificate source |
| `certmanager_dns_provider` | desec | desec | DNS-01 challenge provider |
| `crowdsec_online_api` | true | false | Community blocklist + console enrollment |
| `loki_storage_type` | s3 | filesystem | Log storage backend |
| `loki_retention_days` | 60 | 7 | Log retention |
| `prometheus_retention` | 180d | 15d | Metrics retention |
| `authelia_smtp_scheme` | submissions | smtp | SMTP notifier TLS |
| `timezone` | UTC | Europe/Paris | Default timezone for apps |

### PVC sizes

All PVC sizes are configurable. Override per target for different storage needs.

| Arg | Default | Used by |
|-----|---------|---------|
| `pvc_prometheus` | 50Gi | Prometheus TSDB |
| `pvc_loki` | 10Gi | Loki (single binary) |
| `pvc_garage` | 20Gi | Garage S3 object storage |
| `pvc_registry` | 10Gi | Pull-through cache |
| `pvc_homeassistant` | 5Gi | Home Assistant config |
| `pvc_seafile` | 5Gi | Seafile data |
| `pvc_mailserver_data` | 10Gi | Mailserver mailboxes |
| `pvc_mailserver_state` | 1Gi | Mailserver state |
| `pvc_mailserver_log` | 1Gi | Mailserver logs |
| `pvc_mariadb` | 2Gi | MariaDB databases |
| `pvc_crowdsec` | 1Gi | CrowdSec LAPI |
| `pvc_ntfy` | 1Gi | ntfy cache |
| `pvc_parsedmarc` | 1Gi | Parsedmarc data |
| `pvc_zigbee2mqtt` | 256Mi | Zigbee2MQTT config |
| `pvc_mosquitto` | 256Mi | Mosquitto persistence |

### Replica counts

Scalable services have configurable replicas. Singletons (garage, seafile,
zigbee2mqtt, mosquitto) stay at 1 by design.

| Arg | Default | Service |
|-----|---------|---------|
| `replicas_authelia` | 1 | Authelia SSO |
| `replicas_loki` | 1 | Loki (single binary) |
| `replicas_whoami` | 1 | Whoami test |
| `replicas_gatus` | 1 | Gatus health checks |
| `replicas_ntfy` | 1 | ntfy push |
| `replicas_mta_sts` | 1 | MTA-STS policy server |
| `replicas_autodiscover` | 1 | Mail autodiscover |

### Device paths

For hardware-bound services (USB dongles). Override per target for different hardware.

| Arg | Default | Used by |
|-----|---------|---------|
| `homeassistant_usb_host_path` | /dev/serial/by-id | Home Assistant USB passthrough |
| `zigbee2mqtt_usb_device_path` | /dev/ttyUSB0 | Zigbee2MQTT coordinator |

### Email senders (derived)

Derived from `cluster_domain` in `targets/defaults.yaml`:

| Arg | Derived value | Used by |
|-----|--------------|---------|
| `noreply_email` | noreply@{domain} | SMTP notifier |
| `alertmanager_from_email` | alertmanager@{domain} | Alertmanager |
| `authelia_sender_email` | authelia@{domain} | Authelia notifications |
