# Destr0yer server build recipe

## Installation
HDD: 50Go
Language : English
Keyboard : French
Location : Europe/Paris

## Partitioning
Guided using LVM :
	- /home, /var, /temp separate folders

## Network

Hostname : destr0yer-N.pool.youtous.me

## Software

- SSH server
- standard system utilities

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

- Launch the recipe using : `ansible-playbook -i hosts.yml playbook.yml --vault-password-file ./.vault_password`
- Edit secrets using  : `ansible-vault edit secret_vars/all.yml --vault-password-file ./.vault_password`

## Ansible 3rd Roles

- https://github.com/fubarhouse/ansible-role-golang
- https://github.com/unxnn/ansible-users