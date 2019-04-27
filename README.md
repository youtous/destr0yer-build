# Destr0yer playbooks

## Installation
*Tested on Debian (9) Strech only.*

Please fork this repo for each different server configuration.

## Requirements Software

- SSH access
- Python

## VM only

Install `vim`.

**Network** : use briged, set a fixed ip on the virtual machine.


Edit `/etc/network/interfaces`
```
auto enp0s3
iface enp0s3 inet static
	address 192.168.1.89
	netmask 255.255.255.0
	gateway 192.168.1.1
```

Then restart networking : `systemctl restart networking`

Allow root login `/etc/ssh/sshd_config`
```
PermitRootLogin yes
```

## Ansible usage

- Launch the recipe using : `ansible-playbook -i hosts/hosts.yml destr0yers.yml --vault-password-file ./.vault_password`
- Edit secrets using  : `env EDITOR=vim ansible-vault edit secret_vars/all.yml --vault-password-file ./.vault_password`

## Playbooks description :

- **destr0yers** : this play setup debian based systems with a secured base configuration. Use it as a _base_.
- **the-swarm** : this play setup a Docker Swarm network using several nodes. It use TLS for communications between nodes (requires CA setup).
Use it for Docker infrastructures.

## Hosts

Hosts are located in `hosts/{hosts groups list}.yml`. Use separate files for separate clusters.

## A word about Create CA

Using a personal Root CA is useful for swarm mode over TLS.
Details of the procedure are available on : https://gist.github.com/fntlnz/cf14feb5a46b2eda428e000157447309
**Important :** use a secure encryption for root CA using `openssl genrsa -chacha20...`

To sum up :
- Root CA 
    1. RootCA (private !) : `openssl genrsa -chacha20 -out certs/heaven.youtous.me-rootCA.key 4096`
    2. Root CERTIFICATE (crt) (to be shared and renewed in 2500 days) : `openssl req -x509 -new -nodes -key certs/heaven.youtous.me-rootCA.key -sha256 -days 2500 -out certs/heaven.youtous.me-rootCA.crt`
- For each server :
    1. Certificate key (private !) : `openssl genrsa -out certs/heaven-pascal.youtous.me.key 4096`
    2. Certificate signing (csr) : `openssl req -new -key certs/heaven-pascal.youtous.me.key -out certs/heaven-pascal.youtous.me.csr`
    3. Generate the CERTIFICATE (crt) (to be renewed in 1024 days) : `openssl x509 -req -in certs/heaven-pascal.youtous.me.csr -CA certs/heaven.youtous.me-rootCA.crt -CAkey certs/heaven.youtous.me-rootCA.key -CAcreateserial -out certs/heaven-pascal.youtous.me.crt -days 1024 -sha256`
    4. Next time, don't use `-CAcreateserial` but `-CAserial certs/heavean.youtous.me-rootCA.srl` (http://users.skynet.be/pascalbotte/art/server-cert.htm)
    5. On the certificate has been generated, it to host secrets, there is no need to save it.

*Notes :*

 - chacha20 is currently secured enought and resists against timing guess attacks
 - All digest are broken (https://stackoverflow.com/questions/800685/which-cryptographic-hash-function-should-i-choose/817121#817121) 

## Ansible 3rd Roles

Install requirements using
`ansible-galaxy install -r requirements.yml`

*See requirements.yml*