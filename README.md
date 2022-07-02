# Destr0yer playbooks - Simple, Secure, Docker Swarm cluster using ansible

[![pipeline status](https://gitlab.com/youtous/destr0yer-build/badges/master/pipeline.svg)](https://gitlab.com/youtous/destr0yer-build/-/commits/master)
[![pre-commit](https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit&logoColor=white)](https://github.com/pre-commit/pre-commit)
[![Licence](https://img.shields.io/github/license/youtous/destr0yer-build)](https://github.com/youtous/destr0yer-build/blob/master/LICENSE)

## Requirements

On your computer:

    - python3, pip3
    - openssl
    - terraform
    - ansible (>= 2.9)
    - bash
    - jq
    - ruby

*Tested on Debian 10 Buster only.*

### Ansible 3rd content

Install requirements using
`ansible-galaxy install -r requirements.yml`

*See requirements.yml*

## Playbooks

Each playbook interact with a given scope:

- `provision.yml`: install requirements for newly created servers
- `configure.yml`: setup an initial server installation, aimed for a general purpose
- `swarm.yml`: setup the docker-swarm cluster and associated tools (reverse proxy, scheduler, etc)
- `elastic.yml`: setup an elastic cluster
- `mailserver.yml`: setup a mailserver server
- `teamspeak.yml`: setup a teamspeak server
- `nextcloud.yml`: setup a nextcloud server

During the **first installation**, the playbooks should be executed in the following order:

0. Add servers to the `factoring_systems` in `hosts/instances.yml`
1. Execute playbooks: `provision.yml` then `configure.yml` and finally `swarm.yml`

## Getting started - simplified example

- `source vault.fish` - register the secret passphrase for secrets
- `ansible-galaxy install -r requirements.yml` - install requirements
- `ansible-playbook -i hosts/instances.yml provision.yml --vault-password-file "./.vault_password" --user=debian` - provision the cluster
- `ansible-playbook -i hosts/instances.yml configure.yml --vault-password-file "./.vault_password"` - provision the cluster
- `ansible-playbook -i hosts/instances.yml swarm.yml --vault-password-file "./.vault_password"` - configure the swarm cluster

You can use `ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook` to avoid ssh-key trust confirmation.

### Docker-Swarm

- Docker-Swarm requires a X509 root CA. A certificate for each node should be generated too: generate it using `generate-X509-certificate.rb`

### Other commands
- `bcrypt-passwd.sh` : helps to create a bcrypt password; requires `htpasswd` to be installed.

### Save `secrets` and `certs`
Using `make` and the **Makefile** you can easily save secrets and certs in a safe place. For instance a private _Nextcloud_.
- `make push` - save secrets and certs
- `make pull` - restore secrets and certs

_Create a `.env` as `.env.sample` in order to configure save path and cluster name which must be unique._

## Getting started - detailed version

### I. Infrastructure provisioning - Vagrant _(dev only)_

- Start machines using `vagrant up`.
- Stop machines using `vagrant halt`.
- Update /etc/hosts using `vagrant hostmanager`

[vagrant-hostmanager](https://github.com/devopsgroup-io/vagrant-hostmanager) plugin is used for name resolution.

If logs grows due to systemd not capable to generate a MAC address, see https://github.com/systemd/systemd/issues/3374#issuecomment-452718898

### TODO : include the detailed installation there

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
logstash_client_forwarder_ca_certificate: "" # CA shared with the logstash receiver, this is required when used as a forwarder
logstash_client_forwarder_node_certificate: ""
logstash_client_forwarder_node_private_key: ""
```
2. On the elastic client node: generate a rootCA used for generating certificates in the swarm cluster.
```yaml
logstash_ca_certificate: | # usually logstash-rootCA.crt
logstash_node_private_key: | # usually logstash-node-hostname.key
logstash_node_certificate: | # usually logstash-node-hostname.crt
```
See `docker-elastic` for detailed instructions.

## Licence

Destr0yer-build https://github.com/youtous/destr0yer-build Author @youtous.
This project is licenced under the GPLv3, see LICENCE for details.
