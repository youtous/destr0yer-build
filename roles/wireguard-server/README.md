# ansible/wireguard-server

## Setup server

See default/main.yml

## Setup client (peer)

`wg0.cf`
```toml
[Interface]
PrivateKey = CLIENT_PRIVATE_KEY
Address = 10.0.0.2/24,fdc9:281f:04d7:9ee9::2/64 # <--- set client ip here
DNS = 10.0.0.1, fdc9:281f:04d7:9ee9::1

[Peer]
PublicKey = SERVER_PUBLIC_KEY
PresharedKey = SERVER-CLIENT-PRESHARED_KEY
Endpoint = vpn.localhost.dv:1990
AllowedIPs = 0.0.0.0/0,::/0 # route all traffic trougth the VPN
```