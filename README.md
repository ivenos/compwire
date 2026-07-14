# compwire

Minimal Docker image running WireGuard as a **server** or **client**, configured entirely via environment variables.

```
ivenos/compwire:latest
```

Requires the `NET_ADMIN` capability and a Linux kernel ≥ 5.6 (WireGuard built-in).

---

## Quick start

1. Generate keypairs for each node:

   ```sh
   docker run --rm ivenos/compwire genkey
   ```

2. Copy [`compose.yml`](compose.yml) and fill in all `<...>` placeholders with your keys.

3. Start:

   ```sh
   docker compose up -d
   docker compose logs -f
   ```

The `compose.yml` runs one server and one client on the same host. In production each node runs on its own machine with `WG_SERVER_ENDPOINT` pointing to the server's public IP or hostname. See [`examples/`](examples/) for multi-client, full-tunnel, and IPv6 setups.

---

## Environment variables - Server

Peer IDs (`<ID>`) must be uppercase alphanumeric, e.g. `LAPTOP`, `NODE1`.

| Variable | Required | Default | Description |
|---|:---:|---|---|
| `WG_ROLE` | ✔️ | - | Must be `server` |
| `WG_PRIVATE_KEY` | ✔️¹ | - | WireGuard private key (base64) |
| `WG_PRIVATE_KEY_FILE` | ✔️¹ | - | Path to file containing the private key |
| `WG_PEER_<ID>_PUBKEY` | ✔️ | - | Peer public key |
| `WG_PEER_<ID>_ALLOWED_IPS` | ✔️ | - | Allowed IP ranges for this peer (comma-separated CIDRs) |
| `WG_PEER_<ID>_PSK` | | - | Pre-shared key for this peer |
| `WG_PEER_<ID>_PSK_FILE` | | - | Path to file containing the peer PSK |
| `WG_PEER_<ID>_ENDPOINT` | | - | Peer endpoint `host:port` - enables server-initiated connections to peers with a static IP |
| `WG_PEER_<ID>_KEEPALIVE` | | - | PersistentKeepalive for this peer in seconds (1-65535) |
| `WG_ADDRESS` | | `10.77.0.1/24` | Interface address(es). Comma-separated, supports IPv4, IPv6, and dual-stack (e.g. `10.77.0.1/24,fd00::1/64`) |
| `WG_PORT` | | `51820` | UDP listen port (1-65535) |
| `WG_IFACE` | | `wg0` | Interface name (alphanumeric, `-`, `_`) |
| `WG_DNS` | | - | DNS servers and/or search domains, comma-separated (e.g. `1.1.1.1,8.8.8.8`) |
| `WG_MTU` | | - | Interface MTU (1280-9000) |
| `WG_TABLE` | | - | Routing table: `auto`, `off`, or a numeric table ID |
| `WG_PRE_UP` | | - | Shell command to run before the interface comes up |
| `WG_POST_UP` | | - | Shell command to run after the interface comes up |
| `WG_PRE_DOWN` | | - | Shell command to run before the interface goes down |
| `WG_POST_DOWN` | | - | Shell command to run after the interface goes down |

¹ One of `WG_PRIVATE_KEY` or `WG_PRIVATE_KEY_FILE` is required.

---

## Environment variables - Client

| Variable | Required | Default | Description |
|---|:---:|---|---|
| `WG_ROLE` | ✔️ | - | Must be `client` |
| `WG_PRIVATE_KEY` | ✔️¹ | - | WireGuard private key (base64) |
| `WG_PRIVATE_KEY_FILE` | ✔️¹ | - | Path to file containing the private key |
| `WG_SERVER_PUBKEY` | ✔️ | - | Server public key |
| `WG_SERVER_ENDPOINT` | ✔️ | - | Server address in `host:port` format |
| `WG_ADDRESS` | | `10.77.0.2/24` | Interface address(es). Comma-separated, supports IPv4, IPv6, and dual-stack |
| `WG_PORT` | | - | UDP listen port (1-65535). If unset, the kernel picks a free port |
| `WG_IFACE` | | `wg0` | Interface name (alphanumeric, `-`, `_`) |
| `WG_ALLOWED_IPS` | | `10.77.0.1/32` | Routes to send through the tunnel. Use `0.0.0.0/0` for a full tunnel |
| `WG_KEEPALIVE` | | `25` | PersistentKeepalive in seconds (1-65535) |
| `WG_PSK` | | - | Pre-shared key |
| `WG_PSK_FILE` | | - | Path to file containing the PSK |
| `WG_DNS` | | - | DNS servers and/or search domains, comma-separated |
| `WG_MTU` | | - | Interface MTU (1280-9000) |
| `WG_TABLE` | | - | Routing table: `auto`, `off`, or a numeric table ID |
| `WG_PRE_UP` | | - | Shell command to run before the interface comes up |
| `WG_POST_UP` | | - | Shell command to run after the interface comes up |
| `WG_PRE_DOWN` | | - | Shell command to run before the interface goes down |
| `WG_POST_DOWN` | | - | Shell command to run after the interface goes down |

¹ One of `WG_PRIVATE_KEY` or `WG_PRIVATE_KEY_FILE` is required.

---

## QR code for mobile clients

The WireGuard app for iOS and Android can import a config by scanning a QR code.

**Typical flow** - add a phone as a new client to a running server:

1. Generate a keypair for the phone:
   ```sh
   docker run --rm ivenos/compwire:latest genkey
   ```

2. Add the phone's public key to the server (e.g. `WG_PEER_PHONE_PUBKEY`, `WG_PEER_PHONE_ALLOWED_IPS`).

3. Display the QR code - pass the same env vars you would use for a client container:
   ```sh
   docker run --rm \
     -e WG_ROLE=client \
     -e WG_PRIVATE_KEY=<phone-private-key> \
     -e WG_SERVER_PUBKEY=<server-public-key> \
     -e WG_SERVER_ENDPOINT=vpn.example.com:51820 \
     ivenos/compwire:latest showqr
   ```

4. Scan the QR with the WireGuard app. The config is now on the phone - the container exits and is discarded.

**Already have a running client container?** You can also read its live config directly:

```sh
docker exec <client-container> /entrypoint.sh showqr
```

> **The QR code encodes the private key. Treat it like a secret - do not share or screenshot it in untrusted environments.**

---

## Notes

- Hook commands (`PRE_UP`, `POST_UP`, `PRE_DOWN`, `POST_DOWN`) run as root inside the container. Use `%i` as a placeholder for the interface name (substituted by wg-quick).
- The server healthcheck verifies the interface is up. The client healthcheck additionally checks for a recent peer handshake (≤ 185 s).
- The container logs the initial peer connection state after 30 s and any subsequent changes (full connectivity, partial, or disconnected).
- **IP forwarding** is a host kernel setting, not a container setting. If the server routes traffic between peers (full tunnel with `WG_ALLOWED_IPS=0.0.0.0/0`, or client-to-client as in the multi-client example), enable it on the host: `sysctl -w net.ipv4.ip_forward=1` (persist via `/etc/sysctl.conf` or `/etc/sysctl.d/`). The iptables `FORWARD` rules in the examples are not sufficient on their own.
- With `network_mode: host`, all services in the same Compose file share the host network stack and therefore need distinct `WG_IFACE` values (e.g. `wg0`, `wg1`, `wg2`). Clients don't bind a fixed port unless `WG_PORT` is set; multiple servers additionally need distinct `WG_PORT` values. In production each node runs on its own host, so this does not apply.

---

## License

[BSL 1.1](LICENSE) - free for personal and non-commercial use.
