# ansible/wireguard_server

## Setup server

See default/main.yml

Test leaks using https://ipleak.net/.

#### Key Generation
_from https://wiki.archlinux.org/index.php/WireGuard_

- **public and private key**: `wg genkey | tee peer_A.key | wg pubkey > peer_A.pub`
- **pre-shared key _(one per peer assoc)_**: ` wg genpsk > peer_A-peer_B.psk`

## Setup client (peer)

Example client config for `wg-infra-ext` (ctrl connecting to relay):

```toml
[Interface]
PrivateKey = CLIENT_PRIVATE_KEY
Address = 10.99.99.10/24
# PublicKey = CLIENT_PUBLIC_KEY
# DNS = 10.99.99.1, fdc9:281f:04d7:9ee9::1  # optional: use WG server as DNS resolver

[Peer]
PublicKey = SERVER_PUBLIC_KEY
PresharedKey = SERVER-CLIENT-PRESHARED_KEY
Endpoint = relay-infra:41993
AllowedIPs = 10.99.99.0/24
PersistentKeepalive = 25
```

See `doc/networking.md#wireguard-plane-separation` for the 4-plane topology.
