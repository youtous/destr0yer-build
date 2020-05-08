# ansible/wireguard-client

Test leaks using https://ipleak.net/.

#### Key Generation
_from https://wiki.archlinux.org/index.php/WireGuard_

- **public and private key**: `wg genkey | tee peer_A.key | wg pubkey > peer_A.pub`
- **pre-shared key _(one per peer assoc)_**: ` wg genpsk > peer_A-peer_B.psk`