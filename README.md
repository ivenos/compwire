# compwire

Minimal Docker image running WireGuard as a **server** or **client**, configured entirely via environment variables.

```
ivenos/compwire:latest
```

Requires the `NET_ADMIN` capability and a Linux kernel ≥ 5.6 (WireGuard built-in). Some distributions do not load the module on their own; if the container reports that wg-quick could not bring up the interface, run `modprobe wireguard` on the host.

---

## Quick start

1. Generate keypairs for each node:

   ```sh
   docker run --rm ivenos/compwire genkey
   ```

   For a pre-shared key, use `genpsk` instead.

2. Copy [`compose.yml`](compose.yml) and fill in all `<...>` placeholders with your keys.

3. Start:

   ```sh
   docker compose up -d
   docker compose logs -f
   ```

The `compose.yml` runs one server and one client on the same host. In production each node runs on its own machine with `WG_SERVER_ENDPOINT` pointing to the server's public IP or hostname. See [`examples/`](examples/) for multi-client, full-tunnel, IPv6, and Docker-secrets setups.

Set `WG_ADDRESS` on every client to the address the server lists for it in `WG_PEER_<ID>_ALLOWED_IPS`. If the two disagree, the handshake still succeeds and the healthcheck still reports healthy, but the server drops every packet from that peer.

---

## Environment variables - Server

Peer IDs (`<ID>`) must be uppercase alphanumeric, e.g. `LAPTOP`, `NODE1`.

| Variable | Required | Default | Description |
|---|:---:|---|---|
| `WG_ROLE` | ✔️ | - | Must be `server` |
| `WG_PRIVATE_KEY` | ✔️¹ | - | WireGuard private key (base64) |
| `WG_PRIVATE_KEY_FILE` | ✔️¹ | - | Path to file containing the private key |
| `WG_PEER_<ID>_PUBKEY` | ✔️² | - | Peer public key. Must differ from every other peer's |
| `WG_PEER_<ID>_ALLOWED_IPS` | ✔️² | - | Allowed IP ranges for this peer (comma-separated CIDRs). No range may repeat across peers |
| `WG_PEER_<ID>_PSK` | | - | Pre-shared key for this peer |
| `WG_PEER_<ID>_PSK_FILE` | | - | Path to file containing the peer PSK |
| `WG_PEER_<ID>_ENDPOINT` | | - | Peer endpoint `host:port` (or `[address]:port` for IPv6) - enables server-initiated connections to peers with a static IP |
| `WG_PEER_<ID>_KEEPALIVE` | | - | PersistentKeepalive for this peer in seconds (1-65535) |
| `WG_ADDRESS` | | `10.77.0.1/24` | Interface address(es). Comma-separated, supports IPv4, IPv6, and dual-stack (e.g. `10.77.0.1/24,fd00::1/64`) |
| `WG_PORT` | | `51820` | UDP listen port (1-65535) |
| `WG_IFACE` | | `wg0` | Interface name (alphanumeric, `-`, `_`, at most 15 characters) |
| `WG_DNS` | | - | DNS servers and/or search domains, comma-separated (e.g. `1.1.1.1,8.8.8.8`) |
| `WG_MTU` | | - | Interface MTU (1280-9000) |
| `WG_TABLE` | | - | Routing table: `auto`, `off`, or a numeric table ID (1-4294967295) |
| `WG_PRE_UP` | | - | Shell command to run before the interface comes up |
| `WG_POST_UP` | | - | Shell command to run after the interface comes up |
| `WG_PRE_DOWN` | | - | Shell command to run before the interface goes down |
| `WG_POST_DOWN` | | - | Shell command to run after the interface goes down |

¹ One of `WG_PRIVATE_KEY` or `WG_PRIVATE_KEY_FILE` is required.
² Per peer. A server without any peer starts and warns; it just accepts no connections.

---

## Environment variables - Client

| Variable | Required | Default | Description |
|---|:---:|---|---|
| `WG_ROLE` | ✔️ | - | Must be `client` |
| `WG_PRIVATE_KEY` | ✔️¹ | - | WireGuard private key (base64) |
| `WG_PRIVATE_KEY_FILE` | ✔️¹ | - | Path to file containing the private key |
| `WG_SERVER_PUBKEY` | ✔️ | - | Server public key |
| `WG_SERVER_ENDPOINT` | ✔️ | - | Server address as `host:port`, or `[address]:port` for a literal IPv6 address |
| `WG_ADDRESS` | | `10.77.0.2/24` | Interface address(es). Comma-separated, supports IPv4, IPv6, and dual-stack |
| `WG_PORT` | | - | UDP listen port (1-65535). If unset, the kernel picks a free port |
| `WG_IFACE` | | `wg0` | Interface name (alphanumeric, `-`, `_`, at most 15 characters) |
| `WG_ALLOWED_IPS` | | `10.77.0.1/32` | Routes to send through the tunnel. Use `0.0.0.0/0` for a full tunnel |
| `WG_KEEPALIVE` | | `25` | PersistentKeepalive in seconds (1-65535) |
| `WG_PSK` | | - | Pre-shared key |
| `WG_PSK_FILE` | | - | Path to file containing the PSK |
| `WG_DNS` | | - | DNS servers and/or search domains, comma-separated |
| `WG_MTU` | | - | Interface MTU (1280-9000) |
| `WG_TABLE` | | - | Routing table: `auto`, `off`, or a numeric table ID (1-4294967295) |
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

3. Display the QR code - pass the same env vars you would use for a client container. `WG_ADDRESS` has to match the `WG_PEER_PHONE_ALLOWED_IPS` from step 2, and `WG_ALLOWED_IPS` decides what the phone sends through the tunnel:
   ```sh
   docker run --rm \
     -e WG_ROLE=client \
     -e WG_PRIVATE_KEY=<phone-private-key> \
     -e WG_ADDRESS=10.77.0.5/32 \
     -e WG_SERVER_PUBKEY=<server-public-key> \
     -e WG_SERVER_ENDPOINT=vpn.example.com:51820 \
     -e WG_ALLOWED_IPS=10.77.0.0/24 \
     ivenos/compwire:latest showqr
   ```

4. Scan the QR with the WireGuard app. The config is now on the phone - the container exits and is discarded.

**Already have a running client container?** `showqr` works there too, but it rebuilds the config from that container's environment and rewrites `/etc/wireguard/<iface>.conf` in the process. It does not read the running tunnel, and a phone needs its own key pair anyway:

```sh
docker exec <client-container> /entrypoint.sh showqr
```

> **The QR code encodes the private key. Treat it like a secret - do not share or screenshot it in untrusted environments.**

---

## Notes

- Hook commands (`PRE_UP`, `POST_UP`, `PRE_DOWN`, `POST_DOWN`) run as root inside the container. Use `%i` as a placeholder for the interface name (substituted by wg-quick).
- The server healthcheck verifies the interface is up. The client healthcheck additionally checks for a recent peer handshake (≤ 185 s, or `WG_KEEPALIVE` + 125 s once the keepalive exceeds 60 s, since a longer keepalive stretches the interval between handshakes).
- The container logs the initial peer connection state after 30 s and any subsequent changes (full connectivity, partial, or disconnected).
- `WG_SERVER_ENDPOINT` is resolved once, when the interface comes up. If the server's address changes behind a hostname, the client keeps sending to the old one and goes unhealthy; Docker does not restart on unhealthy, so that needs a `docker restart` (or a watchdog).
- **Secrets:** a value passed as an environment variable stays readable in `docker inspect` and `/proc/<pid>/environ` for the container's whole lifetime. The `*_FILE` variants avoid that, see [`examples/secrets.yaml`](examples/secrets.yaml).
- **IP forwarding** is a host kernel setting, not a container setting. If the server routes traffic between peers (full tunnel with `WG_ALLOWED_IPS=0.0.0.0/0`, or client-to-client as in the multi-client example), enable it on the host: `sysctl -w net.ipv4.ip_forward=1` (persist via `/etc/sysctl.conf` or `/etc/sysctl.d/`). The iptables `FORWARD` rules in the examples are not sufficient on their own.
- **Full tunnel** clients need one more host setting: `sysctl -w net.ipv4.conf.all.src_valid_mark=1`. For a `0.0.0.0/0` route wg-quick sets this itself, but `/proc/sys` is read-only inside a container, so the write fails and takes wg-quick down with it. Set on the host, wg-quick skips it.
- With `network_mode: host` the WireGuard interface lives in the host's network namespace and outlives a container that was killed rather than stopped. On start compwire reclaims such an interface if it carries its own public key, and refuses to start if the interface belongs to anything else.
- With `network_mode: host`, all services in the same Compose file share the host network stack and therefore need distinct `WG_IFACE` values (e.g. `wg0`, `wg1`, `wg2`). Clients don't bind a fixed port unless `WG_PORT` is set; multiple servers additionally need distinct `WG_PORT` values. They also share one routing table: two clients of the same server both want a route to its tunnel address, and the second one fails with `RTNETLINK answers: File exists`. A server plus one client works, two clients need two hosts. In production each node runs on its own host, so this does not apply.

---

## License

[BSL 1.1](LICENSE) - free for personal and non-commercial use.
