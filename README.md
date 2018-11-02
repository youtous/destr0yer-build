# Destr0yer server build recipe

## Installation
Language : English
Keyboard : French
Location : Europe/Paris

## Partioning
Guided using LVM :
	- /home, /var, /temp separate folders

## Network

Hostname : destr0yer-N.pool.youtous.me

## Softwares

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