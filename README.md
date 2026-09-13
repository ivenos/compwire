<div align="center">

<img alt="compwire" src="https://raw.githubusercontent.com/ivenos/compwire/main/.github/assets/compwire-logo.svg" width="50%">

<a href="https://hub.docker.com/r/ivenos/compwire"><picture><source media="(prefers-color-scheme: dark)" srcset="https://shieldcn.dev/docker/size/ivenos/compwire.svg?variant=secondary&amp;mode=dark"><img alt="Docker Image Size" src="https://shieldcn.dev/docker/size/ivenos/compwire.svg?variant=secondary&amp;mode=light"></picture></a>
<a href="https://hub.docker.com/r/ivenos/compwire"><picture><source media="(prefers-color-scheme: dark)" srcset="https://shieldcn.dev/docker/pulls/ivenos/compwire.svg?variant=secondary&amp;mode=dark"><img alt="Docker Pulls" src="https://shieldcn.dev/docker/pulls/ivenos/compwire.svg?variant=secondary&amp;mode=light"></picture></a>
<a href="https://github.com/ivenos/compwire/blob/main/LICENSE"><picture><source media="(prefers-color-scheme: dark)" srcset="https://shieldcn.dev/badge/license-GPL_3.0.svg?variant=secondary&amp;mode=dark"><img alt="License" src="https://shieldcn.dev/badge/license-GPL_3.0.svg?variant=secondary&amp;mode=light"></picture></a>

compwire is a minimal Docker image running WireGuard as a server or client, configured entirely via environment variables.

</div>

---

## Quick start

compwire needs a Linux host with WireGuard in the kernel (5.6 or newer). If the log says wg-quick could not bring up the interface, run `modprobe wireguard` on the host.

Generate a key pair for each node. `genpsk` prints a pre-shared key instead.

```sh
docker run --rm ivenos/compwire genkey
```

### Server

```yaml
services:
  compwire:
    image: ivenos/compwire:latest
    network_mode: host
    cap_drop: [ALL]
    cap_add: [NET_ADMIN]
    environment:
      WG_ROLE: server
      WG_PRIVATE_KEY: <server-private-key>
      WG_ADDRESS: 10.77.0.1/24
      WG_PEER_CLIENT_PUBKEY: <client-public-key>
      WG_PEER_CLIENT_ALLOWED_IPS: 10.77.0.2/32
    restart: unless-stopped
```

Add one `WG_PEER_<ID>_*` block per client. UDP port 51820 has to be reachable from the clients.

### Client

```yaml
services:
  compwire:
    image: ivenos/compwire:latest
    network_mode: host
    cap_drop: [ALL]
    cap_add: [NET_ADMIN]
    environment:
      WG_ROLE: client
      WG_PRIVATE_KEY: <client-private-key>
      WG_ADDRESS: 10.77.0.2/32
      WG_SERVER_PUBKEY: <server-public-key>
      WG_SERVER_ENDPOINT: vpn.example.com:51820
    restart: unless-stopped
```

`WG_ADDRESS` has to match what the server sets in `WG_PEER_<ID>_ALLOWED_IPS` for this client. Otherwise the handshake succeeds, but the server drops every packet.

Start both with `docker compose up -d`. The [examples](https://github.com/ivenos/compwire/tree/main/examples) cover several clients, a full tunnel, an IPv6 endpoint and Docker secrets.

## Environment variables

### Both roles

| Variable | Default | Description |
|---|---|---|
| `WG_ROLE` | - | `server` or `client` (required) |
| `WG_PRIVATE_KEY` | - | Private key of this node (required, or `WG_PRIVATE_KEY_FILE`) |
| `WG_PRIVATE_KEY_FILE` | - | File containing the private key |
| `WG_ADDRESS` | Server `10.77.0.1/24`, client `10.77.0.2/32` | Tunnel address, comma-separated for IPv4 and IPv6 |
| `WG_PORT` | Server `51820`, client random | UDP listen port. Servers sharing the host network each need their own |
| `WG_IFACE` | `wg0` | Interface name, at most 15 characters. Containers sharing the host network each need their own |
| `WG_DNS` | - | DNS servers and search domains for the container's own resolver, comma-separated, at least one server |
| `WG_MTU` | - | Interface MTU, 1280-9000 |
| `WG_TABLE` | - | Routing table: `auto`, `off` or a table ID |
| `WG_PRE_UP` | - | Shell command run before the interface comes up |
| `WG_POST_UP` | - | Shell command run after the interface comes up |
| `WG_PRE_DOWN` | - | Shell command run before the interface goes down |
| `WG_POST_DOWN` | - | Shell command run after the interface goes down |

Hook commands run as root inside the container. `%i` stands for the interface name.

### Server

`<ID>` names the peer in uppercase letters and digits, e.g. `WG_PEER_NODE1_PUBKEY`.

| Variable | Default | Description |
|---|---|---|
| `WG_PEER_<ID>_PUBKEY` | - | Public key of the peer (required) |
| `WG_PEER_<ID>_ALLOWED_IPS` | - | Addresses routed to the peer, comma-separated CIDRs (required) |
| `WG_PEER_<ID>_PSK` | - | Pre-shared key |
| `WG_PEER_<ID>_PSK_FILE` | - | File containing the pre-shared key |
| `WG_PEER_<ID>_ENDPOINT` | - | `host:port` or `[address]:port` of a peer with a fixed address, so the server can connect first |
| `WG_PEER_<ID>_KEEPALIVE` | - | Keepalive in seconds, 1-65535 |

### Client

| Variable | Default | Description |
|---|---|---|
| `WG_SERVER_PUBKEY` | - | Public key of the server (required) |
| `WG_SERVER_ENDPOINT` | - | Server as `host:port` or `[address]:port` (required). A hostname is resolved once at startup |
| `WG_ALLOWED_IPS` | `10.77.0.1/32` | Destinations routed through the tunnel, comma-separated CIDRs. `0.0.0.0/0` for a full tunnel |
| `WG_KEEPALIVE` | `25` | Keepalive in seconds, 1-65535 |
| `WG_PSK` | - | Pre-shared key |
| `WG_PSK_FILE` | - | File containing the pre-shared key |

## Routing through the server

A full tunnel and traffic between clients both need IP forwarding on the server host:

```sh
sysctl -w net.ipv4.ip_forward=1
```

A full-tunnel client also needs this on its own host:

```sh
sysctl -w net.ipv4.conf.all.src_valid_mark=1
```

Neither can be set from inside the container. The matching iptables rules are in the [full-tunnel](https://github.com/ivenos/compwire/blob/main/examples/full-tunnel.yaml) and [multi-client](https://github.com/ivenos/compwire/blob/main/examples/multi-client.yaml) examples.

## License

Copyright © 2026 Iven Schlösser. compwire is free software, licensed under the [GNU General Public License v3.0 only](https://github.com/ivenos/compwire/blob/main/LICENSE). You may use, modify and redistribute it. Anyone distributing a modified version must release it under the same license and make its source code available.

The Docker image is built on Alpine Linux and ships wireguard-tools and other packages, each under its own license.

compwire is not affiliated with or endorsed by the WireGuard project. "WireGuard" and the "WireGuard" logo are registered trademarks of Jason A. Donenfeld.
