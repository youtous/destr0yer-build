# Destr0yer playbooks - Simple, Secure, Docker Swarm cluster using ansible

[![pipeline status](https://gitlab.com/youtous/destr0yer-build/badges/master/pipeline.svg)](https://gitlab.com/youtous/destr0yer-build/-/commits/master)
[![pre-commit](https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit&logoColor=white)](https://github.com/pre-commit/pre-commit)
[![Debian - 12 (Bookworm)](https://img.shields.io/badge/Debian-12(Bookworm)-a80030)](https://www.debian.org/releases/bookworm/releasenotes)
[![Docker Swarm](https://img.shields.io/badge/Docker-Swarm-2496ed)](https://github.com/moby/swarmkit)
[![Caddy v2](https://img.shields.io/badge/Caddy-v2-03af19)](https://github.com/traefik/traefik)
[![Traefik v2](https://img.shields.io/badge/Traefik-v2-37abc8)](https://github.com/traefik/traefik)
[![GitHub Repo stars](https://img.shields.io/github/stars/youtous/destr0yer-build?label=✨%20youtous%2Fdestr0yer-build&style=social)](https://github.com/youtous/destr0yer-build/)
[![Gitlab Repo](https://img.shields.io/badge/gitlab.com%2Fyoutous%2Fdestr0yer--build?label=✨%20youtous%2Fdestr0yer-build&style=social&logo=gitlab)](https://gitlab.com/youtous/destr0yer-build/)
[![Licence](https://img.shields.io/github/license/youtous/destr0yer-build)](https://github.com/youtous/destr0yer-build/blob/master/LICENSE)

# TODO:
- [ ] refactor ufw rule manipulation using a role + add tests in the role (ufw rules are deleted but others are kept) + instead of shell yes, just use ufw --force delete 2
- check swarm installation on bookworm
- start k3s installation

## Requirements

On your computer:

  - python3, pip3, pipenv
  - openssl (certificate management)
  - htpasswd (generate basic auth passwords)
  - ansible (>= 5)
  - bash
  - jq (used in the roles)
  - netaddr (used in the roles)
  - ruby (optional if you don't mind using certificate scripts)
  - (optional) [step-cli](https://github.com/smallstep/cli)

Install python dependencies: `pipenv install`

### Ansible 3rd content

Install requirements using
`ansible-galaxy install -r requirements.yml`

*See requirements.yml*

## Playbooks

Each playbook interact with a given scope:

- `00-provision.yml`: install requirements for newly created servers
- `01-configure.yml`: setup an initial server installation, aimed for a general purpose
- `02-swarm.yml`: setup the docker-swarm cluster and associated tools (reverse proxy, scheduler, etc)
- `90-elastic.yml`: setup an elastic cluster
- `90-mailserver.yml`: setup a mailserver server
- `90-teamspeak.yml`: setup a teamspeak server
- `90-nextcloud.yml`: setup a nextcloud server

During the **first installation**, the playbooks should be executed in the following order:

0. Add the servers in either `base_systems` or `commander_systems` in `hosts/base-nodes.yml`
1. Execute playbooks: `00-provision.yml` then `01-configure.yml` and finally `02-swarm.yml`

## Getting started - simplified example

- `pipenv install && pipenv shell` - open a virtualenv shell
- `source vault.fish` - register the secret passphrase for secrets
- `ansible-galaxy install -r requirements.yml` - install requirements
- `ansible-playbook -i inventories/dev/base-nodes.yml playbooks/00-provision.yml --vault-password-file "./.vault_password"  --extra-vars='nameservers=["1.1.1.1"]' --user=root` - provision the cluster (only needed once)
- `ansible-playbook -i inventories/dev/base-nodes.yml playbooks/01-configure.yml --vault-password-file "./.vault_password"` - configure the cluster
- `ansible-playbook -i inventories/dev/swarm-nodes.yml playbooks/02-swarm.yml --vault-password-file "./.vault_password"` - configure the swarm cluster

You can use `ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook` to avoid ssh-key trust confirmation.

### Useful commands

- Docker-Swarm, Elastic, MariaDB and other services require a X509 root CA. The generation can be simplified using `generate-X509-certificate.rb`, `step-cli` is also a good candidate for managing certificates.
- `bcrypt-passwd.sh` : helps to create a bcrypt password; requires `htpasswd` to be installed.

### Save `secrets` and `certs`

Using `make` and the **Makefile** you can easily save secrets and certs in a safe place. For instance a private _Nextcloud_.
- `make push` - save secrets and certs
- `make pull` - restore secrets and certs

_Create a `.env` as `.env.sample` in order to configure save path and cluster name which must be unique._

## Getting started - detailed version

### I. Infrastructure provisioning

#### Vagrant _(dev only)_

- *Pre-requise*: Install vagrant plugins `vagrant plugin install vagrant-vbguest vagrant-hostmanager`
- Start machines using `vagrant up`.
- Stop machines using `vagrant halt`.
- Update /etc/hosts using `vagrant hostmanager`

[vagrant-hostmanager](https://github.com/devopsgroup-io/vagrant-hostmanager) plugin is used for name resolution.

If logs grows due to systemd not capable to generate a MAC address, see https://github.com/systemd/systemd/issues/3374#issuecomment-452718898

#### Terraform

See https://gitlab.com/deepcube-draft/wp2-deepcube-platform/deepcube-platform-architecture/docker-swarm-infrastructure/-/tree/main/terraform.

### II. Preparing ansible hosts for ignition!

In this step, we will configure the instances using ansible.

1. Create a host inventory file in `host_vars/` for each instance created in the previous step (e.g. `host_vars/myhostname.tld.yml`, the content of the file can be manually or use terraform inventory, have a look in this repo as a reference).
2. Add each freshly created instance in `hosts/base-nodes.yml` in the `factoring_hosts` group:
```
factoring_systems:
  hosts:
    myhostname.tld:
```

This step allow ansible to prepare a freshly created instance. This step is only ran the first time (on the provisioning stage).

3. Then `source vault.fish` - register the secret passphrase for secrets
4. Install the requirements `ansible-galaxy install -r requirements.yml`
5. Create a global vault for storing sensible variables (passwords etc): `ansible-vault create secret_vars/{{ server_environment }}/all.yml  --vault-password-file "./.vault_password"` (example can be found in `all.sample.yml`)
    - Provide a password for the sudo admin user `sudo_user_password` using `openssl passwd -6`, also save the password in `sudo_user_clear_password`
    - Generate a root password the same, it is not required to save this password as long as you have a sudo user.
    - Add your ssh **public** keys in `sudo_user_ssh_keys`
    - Generate a basic auth user used for http admin auth in `backend_users` using `./bcrypt-password.sh <admin username>` then get the base64 of it using `echo -n 'my-bcrypt-password' | base64`
6. Repeat the previous step for each instance: `ansible-vault create secret_vars/{{ server_environment }}/myhostname.tld.yml  --vault-password-file "./.vault_password"`. Instance's specific secrets.

### III. Initial configuration for freshly created instance (bootstrap configuration)

Each newly created instance needs to be configured by ansible using a dedicated preparation playbook.

1. Ensure the newly created instances are listed in the group `systems` in `hosts/base-nodes.yml` (either in `base_systems` or `commander_systems`)
2. Run the playbook with a root user: `ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i inventories/dev/base-nodes.yml playbooks/00-provision.yml --vault-password-file "./.vault_password" --extra-vars='nameservers=["1.1.1.1"]' --user=root`

### IV. Configure the instances (system configuration)

1. Configure the desired state of the cluster in `group_vars/all.yml` (**important:** please define a list of allowed ssh ips using `ssh_entrypoints`)
2. Configure instance specifities using its dedicated configuration file in `host_vars/myhostname.tld.yml`, see examples in `hosts/`.
3. Run the playbook on the instances, it will setup all the system configuration in a single run: `ansible-playbook -i inventories/dev/base-nodes.yml playbooks/01-configure.yml --vault-password-file "./.vault_password"`

#### Server keys generation

The backup configuration requires ssh keys and gpg keys to be generated from your host and then saved in the related vaults.

##### Generate ssh keys

For each account present on the server, a couple of public and private key is required. Generate it using `ssh-keygen -q -t ed25519 -C "" -N ""`
and save it in the secret vault.

#### Generate GPG keys for backup encryption

Backups are encrypted using GPG.

_The following step are from this guide: https://github.com/Oefenweb/ansible-duply-backup#advance-configuration-gpg-enabled_

1. Generate a new GPG key using: `gpg --full-gen-key` _(choose RSA and RSA, 4096bits, never expires)_
2. Export the public key using: `gpg --output {public key name}.pub.asc --armor --export {the name you entered previously}`
3. Export the private key using: `gpg --output {private key name}.sec.asc --armor --export-secret-key {the name you entered previously}`
4. Save the public and the private key in the host secret vault.
5. Define this key as encryption key for the backup in `host_vars`. **/!\\** don't forget to set the names and the ownertrust.
6. Save the _ownertrust_, the _both keys_ and the _passphrase_ in a **safe place**.
7. When the export is completed, **delete the GPG key from the host machine**.

### V. Configure the Docker Swarm (cluster configuration)

At this step, the cluster is almost configured. The last step is the docker configuration in swarm mode.

#### V.I Generate the X509 certificates

1. Generate a Root certificate using `./generate-X509-certificate.rb`, type `-1` and enter a root name for the certificate (e.g. `swarm.cluster.dv`). Use a secure passphrase for the certificate and fill the information request. (You can define default values using `certs/openssl.conf` then `export $OPENSSL_CONF=./certs/openssl.conf`)
2. For each node of the cluster, generate a dedicated certificate and sign it using the root CA (e.g. `1.swarm.cluster.dv`, `2.swarm.cluster.dv`, `3.swarm.cluster.dv`), don't set any passphrase on this step.
3. Copy the content of the .crt (certificate) and .key file from `certs/{hostname}.key,crt` it its associated host `secret_vars/{{ server_environment }}/{hostname}.yml`, the variables to fill are `docker_swarm_node_private_key` and `docker_swarm_node_certificate` (`EDITOR='code --wait' ansible-vault edit secret_vars/{{ server_environment }}/{{ server_environment }}/{{ server_environment }}/{{ server_environment }}/hell01.dv.yml  --vault-password-file "./.vault_password"` for interactive editor).
4. Delete the certificate and associated key from `certs/{hostname}.key,crt,csr`
5. Copy the public root certificate from `certs/swarm.cluster.dv-rootCA.crt` to `group_vars/all.yml` in `docker_swarm_CA_certificate` variable.
6. _(eventually)_ backup your root ca files.

__Good practice:__ keep the expiration dates in a calendar with a reminder in order to rotate the Root CA and certificates before expiration.

*Notes :*
 - chacha20 is currently secured enough and resists against timing guess attacks
 - All digest are broken (https://stackoverflow.com/questions/800685/which-cryptographic-hash-function-should-i-choose/817121#817121)

#### V.II Set node roles and register the internal domains

Each docker swarm node can either be a **manager** or a **worker**, see https://docs.docker.com/engine/swarm/how-swarm-mode-works/nodes/.
Choose an appropriate infrastructure architecture then associate each node a role (your node roles must be compliant with the raft algorithm: https://docs.docker.com/engine/swarm/admin_guide/#add-manager-nodes-for-fault-tolerance).

1. Add the **worker** nodes in the group `swarm_workers` in `hosts/swamr-nodes.yml`
2. Add a single **manager** node in the group `swarm_primary_manager` in `hosts/swamr-nodes.yml`
3. Add the others **manager** nodes in the group `swarm_manager` in `hosts/swamr-nodes.yml`
4. Configure the internal services on a dedicated name (`group_vars/all.yml`) using your DNS provider (you should bind it to multiple managers as a DNS round-robin strategy bound):
```yaml
caddy_metrics_domain: "router.swarm.cluster.dv"
consul_ui_domain: "consul.swarm.cluster.dv"
portainer_domain: "portainer.swarm.cluster.dv"
traefik_domain: "traefik.swarm.cluster.dv"

promgraf_domain: "prom.swarm.cluster.dv"
promgraf_prometheus_domain: "prometheus.{{ promgraf_domain }}"
promgraf_grafana_domain: "grafana.{{ promgraf_domain }}"
promgraf_karma_domain: "karma.{{ promgraf_domain }}"
promgraf_alertmanager_domain: "alertmanager.{{ promgraf_domain }}"
```
5. Generate an admin account for portainer, fill `portainer_admin_password` in `secret_vars/{{ server_environment }}/all.yml` using  `docker run --rm httpd:2.4-alpine htpasswd -nbB admin "password" | cut -d ":" -f 2`
6. Generate a random secure value for `consul_acl_master_token` saved in `secret_vars/{{ server_environment }}/{{ server_environment }}/all.yml`, this key is used to encrypt the certificates, generate it using `ruby -e "require 'securerandom'; puts SecureRandom.uuid"`
7. Define a grafana admin password using `promgraf_grafana_admin_password` saved in `secret_vars/{{ server_environment }}/all.yml`

#### V.III Configure the associated elastic cluster

Elastic is bundled with the cluster setup. The installation is optional but recommanded.
If you want to disable elastic, simply set an empty list of hosts for `primary_manager_elastic`, `all_logging_elastic` and `all_metric_elastic` in `hosts/swarm-nodes.yml`.

##### Log forwarding
Two options are available for log forwarding :
- setup an elastic cluster using docker_elastic (see dedicated `roles/docker_elastic/README.md`)
- forward logs using _logstash_ and _wireguard_

The following instructions will detail this last option:
0. On the server node, add a new (peer) wireguard client targeting the new server, see `roles/wireguard_server/README.md`
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
See `docker_elastic` for detailed instructions.

##### Elastic cluster setup (optional)

1. Define a value for `elastic_cluster_name` in `group_vars/all.yml` and domain values for `kibana_domain`, `elasticsearch_domain` and `logstash_domain`. Don't forget to register the DNS entries associated to these domains.
2. Define the list of elastic nodes using `hosts/swamr-nodes.yml`, you can also tweak each deployment value using `elastic_hosts`, `elasticsearch_hosts`, `kibana_hosts`, `logstash_hosts` variables of the **docker_elastic** role.

3. Prepare the x509 certificates:

    - Nodes hostnames must follow a pattern such as `<nodeid>.<clusterid>.domain.tld` (important: `logstash_domain` must be a subdmain)

    - Generate root CA with name : `elastic.<clusterid>.domain.tld`, make sure to indicates the following FQDN for the associated certificate: `<clusterid>.domain.tld`.
    Use `./generate-X509-certificate.rb` to perform the action.

    - For each of the cluster node, generate a certificate using the previously generated RootCA with the following name: `<nodeid>.elastic.<clusterid>.domain.tld` and with the following FQDN: `<nodeid>.<clusterid>.domain.tld`, this certificate will be used by the beat agents on each node to communicate with logstash.

    - Generate a dedicated certificate for each docker service such as **logstash**, (e.g. `logstash.elastic.cluster.dv`, it must be equals to `logstash_domain`!)

    - Please store the certificates in the `secret_vars` folder.

4. Open the logstash ports using traefik in and add the logstash address for beat agents `group_vars/all.yml`:
```yaml
# configure beat agents to communicate with logstash
filebeat_output_server_address: "{{ logstash_domain }}"
journalbeat_output_server_address: "{{ logstash_domain }}"
metricbeat_output_server_address: "{{ logstash_domain }}"

traefik_services:
  - name: logstash-5000
    port: "5000"
    type: tcp
  - name: logstash-5044
    port: "5044"
    type: tcp
  - name: logstash-5064
    port: "5064"
    type: tcp
```

#### V.IV Start the docker-swarm cluster

1. Run the playbook on the instances, it will setup all the docker swarm cluster a single run: `ansible-playbook -i inventories/dev/swamr-nodes.yml playbooks/02-swarm.yml --vault-password-file "./.vault_password"`
2. Go to `portainer_domain` and enjoy your docker swarm cluster! Watch the cluster metrics at `promgraf_grafana_domain`
3. (optional) in case of elastic setup, go to `kibana_domain`
    3.1 Define index-patterns
    _delete can be done in settings > saved objects > filter by pattern_
    In elastic console, add:
    ```http request
    # delete existing indices
    DELETE /docker-*

    # ensure no mapping exists
    GET /docker-*/_mapping/field/source.geo

    # define new mapping
    PUT _template/docker-
    {
    "index_patterns": ["docker-*"],
    "mappings": {
        "properties": {
        "host.name": {
            "type": "keyword"
        },
        "host.hostname": {
            "type": "keyword"
        },
        "cluster.name": {
            "type": "keyword"
        },
        "source.geo": {
            "dynamic": true,
            "properties" : {
                "ip": { "type": "ip" },
                "location" : { "type" : "geo_point" },
                "latitude" : { "type" : "half_float" },
                "longitude" : { "type" : "half_float" }
            }
        },
        "fail2ban_bgp": {
            "dynamic": true,
            "properties" : {
                "ip": { "type": "ip" },
                "location" : { "type" : "geo_point" },
                "latitude" : { "type" : "half_float" },
                "longitude" : { "type" : "half_float" }
            }
        },
        "geoip": {
            "dynamic": true,
            "properties" : {
                "ip": { "type": "ip" },
                "location" : { "type" : "geo_point" },
                "latitude" : { "type" : "half_float" },
                "longitude" : { "type" : "half_float" }
            }
            }
        }
        }
    }
    }
    ```

    3.2 Create the indices patterns using the kibana interface:
    -  `docker-*`, `id=f7f65d60-9946-11ea-ad57-f9074afbf2d7`
    -  `journalbeat-*`, `id=f152ec60-9948-11ea-ad57-f9074afbf2d7`
    -  `metricbeat-*`, `id=metricbeat-*`
    -  `heartbeat-*`, `id=fca68d10-9948-11ea-ad57-f9074afbf2d7`
    -  `filebeat-*`, `id=filebeat-*`

    3.3 Important change due to OpenSearch migration: beats dashboards imports must be performed manually; please read https://www.electricbrain.com.au/pages/analytics/opensearch-vs-elasticsearch.php

## Licence

Destr0yer-build https://github.com/youtous/destr0yer-build Author @youtous.
This project is licenced under the GPLv3, see LICENCE for details.
