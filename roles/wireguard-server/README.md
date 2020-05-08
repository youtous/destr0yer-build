# ansible/wireguard-server

## Setup server

See default/main.yml

#### Key Generation
_from https://wiki.archlinux.org/index.php/WireGuard_

- **public and private key**: `wg genkey | tee peer_A.key | wg pubkey > peer_A.pub`
- **pre-shared key _(one per peer assoc)_**: ` wg genpsk > peer_A-peer_B.psk`

## Setup client (peer)

`wg0.cf`
```toml
[Interface]
PrivateKey = CLIENT_PRIVATE_KEY
Address = 10.0.0.2/24,fdc9:281f:04d7:9ee9::2/64 # <--- set client ip here
DNS = 10.0.0.1, fdc9:281f:04d7:9ee9::1
# PublicKey = CLIENT_PUBLIC_KEY

[Peer]
PublicKey = SERVER_PUBLIC_KEY
PresharedKey = SERVER-CLIENT-PRESHARED_KEY
Endpoint = vpn.localhost.dv:1990
AllowedIPs = 0.0.0.0/0,::/0 # route all traffic trougth the VPN
```