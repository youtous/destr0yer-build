# Destr0yer playbooks

## Installation
*Tested on Debian (9) Strech only.*

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

## Ansible 3rd Roles

Install requirements using
`ansible-galaxy install -r requirements.yml`

*See requirements.yml*