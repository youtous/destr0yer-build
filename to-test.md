# Test checklist

Manual validation items for the destr0yer-build stack.
Run on Vagrant dev cluster after `just configure && just k3s && just deploy`.

---

## Host-level (Ansible)

### MariaDB / PostgreSQL removal

- [ ] `just configure` -- no error about missing `mariadb_server`, `mariadb_client`, `monit_mariadb` roles
- [ ] No `database_servers` or `database_clients` group referenced during run
- [ ] No duply/GPG variables referenced during run
- [ ] `/etc/duply/` does not exist on nodes
- [ ] MariaDB port (3306) not in `ufw status` output
- [ ] `.ansible/roles/geerlingguy.mysql` and `.ansible/roles/geerlingguy.postgresql` absent

### Ansible collection migration (youtous.destr0yer)

- [ ] `just configure` -- no errors about missing `youtous.ufw_smart_rules`, `youtous.users`, `youtous.logwatch` roles
- [ ] UFW rules still applied correctly (collection FQCN `youtous.destr0yer.ufw_smart_rules`)
- [ ] Users created correctly (collection FQCN `youtous.destr0yer.users`)
- [ ] Logwatch configured correctly (collection FQCN `youtous.destr0yer.logwatch`)
- [ ] DNSCrypt-proxy installed via apt (no manual download)
- [ ] `ansible-galaxy collection list` shows `youtous.destr0yer` at path `./collections`
- [ ] No `youtous.*` entries in `requirements.yml` roles section

### WireGuard mesh

- [ ] `wg show wg0` on ctrl shows interface up, listening on port 1990
- [ ] `wg show wg0` on worker shows interface up, peer handshake recent
- [ ] `ping -c3 10.99.99.1` from worker succeeds (ctrl via WG)
- [ ] `ping -c3 10.99.99.2` from ctrl succeeds (worker via WG)
- [ ] Monit check on both nodes: `monit status wg0` shows running
- [ ] UFW on ctrl allows port 1990/udp

### Kopia backup (over WireGuard)

- [ ] `kopia_sftp_host` uses WG IP (`10.99.99.1`) in inventory
- [ ] `systemctl is-active kopia-snapshot.timer` returns active on both nodes
- [ ] `kopia repository status` on both nodes shows connected via SFTP
- [ ] `kopia snapshot list` shows at least one snapshot
- [ ] `systemctl is-active kopia-verify.timer` returns active
- [ ] Backup SFTP traffic flows over wg0 (verify with `ss -tnp | grep 10.99.99`)
- [ ] `backup_storage` UFW allows SSH from `10.99.99.0/24`

### oh-my-fish

- [ ] `source /usr/share/oh-my-fish/init.fish` works without permission error
- [ ] Fish prompt shows hostname colored by environment (cyan for dev)
- [ ] `cat /etc/server_environment` returns `dev`

---

## K8S-level (Kluctl)

### cert-manager

- [ ] `just deploy` -- cert-manager deploys without errors
- [ ] `kubectl get clusterissuer cluster-issuer` -- exists and Ready
- [ ] `kubectl get clusterissuer selfsigned-bootstrap` -- exists (internal-ca mode)
- [ ] `kubectl get certificate -n cert-manager internal-ca` -- Ready, CA cert issued
- [ ] Other components can request certs via `issuerRef.name: cluster-issuer`

### Observability (Prometheus + Grafana + Loki + Alloy + Gatus + testssl)

- [ ] `kubectl get pods -n observability` -- all Running
- [ ] Grafana accessible at `https://grafana.k8s.home`
- [ ] Grafana OIDC login via Authelia works
- [ ] Prometheus targets: all nodes scraped
- [ ] Loki: `logcli query '{namespace="observability"}'` returns logs
- [ ] Alloy DaemonSet running on all nodes, pushing to Loki
- [ ] Gatus health checks passing
- [ ] testssl CronJob: `kubectl get cronjobs -n observability` -- present, last run successful

### Security

- [ ] Kyverno policies: `kubectl get cpol` shows all policies (Audit mode in dev)
- [ ] Kyverno violation report CronJob sends email
- [ ] CrowdSec LAPI + Agent: `kubectl get pods -n security` -- Running
- [ ] CrowdSec collections loaded: `just kubectl exec -n security deploy/crowdsec-lapi -- cscli collections list` shows postfix, dovecot, haproxy, linux, http-cve, base-http-scenarios
- [ ] CrowdSec custom scenario: `just kubectl exec -n security deploy/crowdsec-lapi -- cscli scenarios list` shows custom/postfix-sasl-bf
- [ ] CrowdSec ban report CronJob sends email
- [ ] CrowdSec Online API (prod only, `crowdsec_online_api: true`):
  - [ ] LAPI pod enrolled in console: `just kubectl exec -n security deploy/crowdsec-lapi -- cscli console status`
  - [ ] Community blocklist active: `just kubectl exec -n security deploy/crowdsec-lapi -- cscli decisions list` shows CAPI decisions
  - [ ] CiliumNetworkPolicy `allow-crowdsec-capi` exists: `just kubectl get cnp -n security`
- [ ] Tetragon DaemonSet running, alert CronJob sends email
- [ ] Network policies: default-deny in all app namespaces
- [ ] Reloader: `kubectl get pods -n security -l app.kubernetes.io/name=reloader`

### Storage

- [ ] OpenEBS: `kubectl get sc` shows `openebs-hostpath`
- [ ] Garage: `kubectl get pods -n storage` -- Running
- [ ] Garage admin API: create bucket via `garage bucket create test-bucket`
- [ ] Registry pull-through cache: all 4 proxies running (`kubectl get pods -n registry`)
- [ ] Registry mirrors wired in K3S: `cat /etc/rancher/k3s/registries.yaml` shows docker.io, ghcr.io, quay.io, registry.k8s.io
- [ ] Pull via docker.io mirror: `crictl pull docker.io/library/alpine:3.22` (check registry pod logs for cache hit)
- [ ] Pull via registry.k8s.io mirror: `crictl pull registry.k8s.io/pause:3.10` (check registry pod logs)
- [ ] Velero: `kubectl get pods -n velero` -- Running
- [ ] Velero backup report CronJob sends email
- [ ] Velero backup/restore cycle: create backup, delete resource, restore

### Ingress

- [ ] HAProxy Ingress: `kubectl get pods -n haproxy-ingress` -- Running
- [ ] Global allowlist active (non-trusted IPs blocked by default)
- [ ] Public Ingress override works (MTA-STS, autodiscover accessible from any IP)
- [ ] TLS termination with cert-manager certificates

### Authelia

- [ ] Authelia pod Running: `kubectl get pods -n authelia`
- [ ] Login at `https://auth.k8s.home` with file-based user
- [ ] 2FA TOTP enrollment and login
- [ ] OIDC flow: Grafana "Sign in with Authelia" → redirect → token
- [ ] Session persistence across protected services
- [ ] Logout invalidates session

### Mail stack

- [ ] Mailserver pod Running: `kubectl get pods -n mail`
- [ ] DKIM signing: send test email, check headers
- [ ] TLS on port 465/993: `openssl s_client -connect mail.k8s.home:465`
- [ ] MTA-STS Ingress accessible publicly
- [ ] Autodiscover/Autoconfig Ingress accessible publicly
- [ ] Parsedmarc CronJob processes DMARC reports
- [ ] SMTP notifier account: report CronJobs authenticate and send

### Home Assistant

- [ ] Pod Running: `kubectl get pods -n homeassistant`
- [ ] Web UI accessible via Ingress
- [ ] PVC persists data across restarts

### Firewall rule doubling (provider + host)

Every UFW/nftables rule on bare-metal MUST be doubled at the cloud provider level.

- [ ] Relay node: provider allows only mail ports + WireGuard
- [ ] Bare-metal nodes: provider denies ALL inbound (router NAT blocks)
- [ ] WireGuard port: provider + UFW both allow, same port number
- [ ] After any firewall change: verify both layers match

---

## Future (not yet deployed)

- [ ] Seafile: file sync with Garage S3 + Authelia OIDC + client-side encryption
- [ ] Cloud relay: VPS provisioned, WireGuard tunnel, DNAT mail ports
- [ ] MQTT + Zigbee2MQTT: Mosquitto broker + Zigbee2MQTT for Home Assistant
- [ ] Headscale: human/admin VPN access (deferred, WireGuard PTP for infra)
- [ ] Kyverno Enforce mode: flip from Audit, validate nothing breaks
- [ ] DR test: etcd snapshot restore on Vagrant
