# Destr0yer playbooks

# todo : update the guide

## Daily usage recommendations

 -  **When one of the host ip is changed**, playbook should be completely re-run.

## Installation
*Tested on Debian 10 Buster only.*

Please fork this repo for each different server configuration.

### Requirements
- SSH access
- Python
- python-jmespath

#### VM only
 _*Commands :*_
- Start machines using `vagrant up`.
- Stop machines using `vagrant halt`.
- Update /etc/hosts using `vagrant hostmanager`

[vagrant-hostmanager](https://github.com/devopsgroup-io/vagrant-hostmanager) plugin is used for name resolution.

If logs grows due to systemd not capable to generate a MAC address, see https://github.com/systemd/systemd/issues/3374#issuecomment-452718898
## Ansible Playbooks

### Playbooks description :
- **destr0yers** : this play setup debian based systems with a secured base configuration. Use it as a _base_.
- **the-swarm** : this play setup a Docker Swarm network using several nodes. It use TLS for communications between nodes (requires CA setup).
Use it for Docker infrastructures.

- Edit secrets using : `env EDITOR=vim ansible-vault edit secret_vars/all.yml --vault-password-file ./.vault_password`

#### Deployment of a new node
1. First configuration a new hosts: `ansible-playbook -i hosts/destr0yers.yml  destr0yers.yml --vault-password-file ./.vault_password --tag="new-systems"`
2. Launch the recipe using: `ansible-playbook -i hosts/destr0yers.yml destr0yers.yml --vault-password-file ./.vault_password`
3. Launch the docker recipe using: `ansible-playbook -i hosts/swarm-nodes.yml the-swarm.yml --vault-password-file ./.vault_password`

### Save `secrets` and `certs`
Using `make` and the **Makefile** you can easily save secrets and certs in a safe place. For instance a private _Nextcloud_.
- `make push` - save secrets and certs
- `make pull` - restore secrets and certs

_Create a `.env` as `.env.sample` in order to configure save path and cluster name which must be unique._

### Hosts
Hosts are located in `hosts/{hosts groups list}.yml`. Use separate files for separate clusters.

## How to start?
### Generate ssh keys
For each account present on the server, a couple of public and private key is required. Generate it using `ssh-keygen -q -t ed25519 -C "" -N ""`
and save it in the secret vault.

### Generate GPG keys for backup encryption
Backups requires to be encrypted using GPG.
In order to make it work, keys must be generated.

_We follow this guide: https://github.com/Oefenweb/ansible-duply-backup#advance-configuration-gpg-enabled_
1. Generate a new GPG key using: `gpg --full-gen-key` _(choose RSA and RSA, 4096bits, never expires)_
2. Export the public key using: `gpg --output {public key name}.pub.asc --armor --export {the name you entered previously}`
3. Export the private key using: `gpg --output {private key name}.sec.asc --armor --export-secret-key {the name you entered previously}`
4. Save the public and the private key in the host secret vault.
5. Define this key as encryption key for the backup in `host_vars`. **/!\\** don't forget to set the names and the ownertrust.
6. Save the _ownertrust_, the _both keys_ and the _passphrase_ in a **safe place**.
7. When the export is completed, **delete the GPG key from the host machine**.


### Create CA for swarm or elastic cluster

**Script:** a dedicated scrip has been created for this task. It create a client certificate signed by a root authority (X509 standard).
Use `./generate-X509-certificate.rb`

**REMINDER :** add the expiration date as a comment and as a calendar event.

Using a personal Root CA is useful for swarm mode over TLS.
Details of the procedure are available on : https://gist.github.com/fntlnz/cf14feb5a46b2eda428e000157447309
**Important :** use a secure encryption for root CA using `openssl genrsa -chacha20...`

To sum up :
- Root CA
    1. RootCA (private ! and encrypted using chacha20) : `openssl genrsa -chacha20 -out certs/heaven.youtous.me-rootCA.key 4096`
    2. Root CERTIFICATE (crt) (to be shared and renewed in 2500 days) : `openssl req -x509 -new -nodes -key certs/heaven.youtous.me-rootCA.key -sha256 -days 2500 -out certs/heaven.youtous.me-rootCA.crt`
- For each server :
    1. Certificate key (private ! but not encrypted) : `openssl genrsa -out certs/heaven-pascal.youtous.dv.key 4096`
    2. Certificate signing (csr) : `openssl req -new -key certs/heaven-pascal.youtous.dv.key -out certs/heaven-pascal.youtous.dv.csr`
    3. Generate the CERTIFICATE (crt) (to be renewed in 1024 days) : `openssl x509 -req -in certs/heaven-pascal.youtous.dv.csr -CA certs/heaven.youtous.me-rootCA.crt -CAkey certs/heaven.youtous.me-rootCA.key -CAcreateserial -out certs/heaven-pascal.youtous.dv.crt -days 1024 -sha256`
    4. Next time, don't use `-CAcreateserial` but `-CAserial certs/heaven.youtous.me-rootCA.srl` (http://users.skynet.be/pascalbotte/art/server-cert.htm)
    5. On the certificate has been generated, it to host secrets, there is no need to save it.

*Notes :*
 - chacha20 is currently secured enough and resists against timing guess attacks
 - All digest are broken (https://stackoverflow.com/questions/800685/which-cryptographic-hash-function-should-i-choose/817121#817121)

### Use elastic for logging

Two options are available for log forwarding :
- setup an elastic cluster using docker-elastic (see dedicated `roles/docker-elastic/README.md`)
- forward logs using _logstash_ and _wireguard_

The following instructions will detail this last option:
0. On the server node, add a new (peer) wireguard client targeting the new server, see `roles/wireguard-server/README.md`
1. On the client node, setup a wireguard client connection
```yaml
wireguard_clients:
  - interface: wg-elastic
    name: "{{ hostname }} elastic"
    addresses: # client address + network
      - 10.101.101.2/24
    endpoint: "logstash.castle.youtous.me:1991" # vpn server address
    persistent_keepalive: "" # only used when behind a NAT
    mtu: "" # optional mtu
    allowed_ips: # which traffic to redirect to the vpn?
      - 10.101.101.0/24
    dns: [] # optional DNS ips to use for this VPN
    server_public_key: "server public key=" # public key of the server
    public_key: "client public key=" # client keys
    private_key: "{{ wireguard_elastic_client_private_key }}"
    preshared_key: "{{ wireguard_elastic_client_preshared_key }}"
```
2. Add the client peer ip on the wireguard server to allowed external logstash using
```yaml
logstash_external_allowed_ip4s: # vpn for logstash data exchange
  - "10.101.101.2" # myclient hostname
```

When wireguard tunnel is setup, elastic cluster must be configured:
1. On the elastic master node: generate a client certificate and key used by the client node for submitting data to the elastic receiver.
```yaml
# on the forwarder node
logstash_client_forwarder_CA_certificate: "" # CA shared with the logstash receiver, this is required when used as a forwarder
logstash_client_forwarder_node_certificate: ""
logstash_client_forwarder_node_private_key: ""
```
2. On the elastic client node: generate a rootCA used for generating certificates in the swarm cluster.
```yaml
logstash_CA_certificate: | # usually logstash-rootCA.crt
logstash_node_private_key: | # usually logstash-node-hostname.key
logstash_node_certificate: | # usually logstash-node-hostname.crt
```
See `docker-elastic` for detailed instructions.

### Examples
#### DockerSwarm hosts
Swarm comes with several admin applications which require domains,
here is a list of the required domains :

```
# prom domains
192.168.100.10  prom.prom.heaven-pascal.youtous.dv
192.168.100.10  unsee.prom.heaven-pascal.youtous.dv
192.168.100.10  alerts.prom.heaven-pascal.youtous.dv
192.168.100.10  graph.prom.heaven-pascal.youtous.dv

# traefik domains
192.168.100.10  traefik.heaven-pascal.youtous.dv
192.168.100.10  consul.heaven-pascal.youtous.dv

# portainer
192.168.100.10  portainer.heaven-pascal.youtous.dv

# elastic stack
192.168.100.10  kibana.heaven-pascal.youtous.dv
192.168.100.10  elasticsearch.heaven-pascal.youtous.dv
192.168.100.10  logstash.heaven-pascal.youtous.dv

# nextcloud
192.168.100.10  cloud.heaven-pascal.youtous.dv

# mailserver
192.168.100.10 mail.heaven-pascal.youtous.dv
192.168.100.10 autodiscover.heaven-pascal.youtous.dv
192.168.100.10 autoconfig.heaven-pascal.youtous.dv

```

### Other commands
- `bcrypt-passwd.sh` : helps to create a bcrypt password; requires `htpasswd` to be installed.

## Ansible 3rd Roles

Install requirements using
`ansible-galaxy install -r requirements.yml`

*See requirements.yml*
*Ansible version:* _2.8_
