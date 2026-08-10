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

Peer IDs (`<ID>`) must be uppercase letters and digits with no underscore, e.g. `LAPTOP`, `NODE1`. A `WG_PSK` set on a server is ignored with a warning; pre-shared keys belong to the individual peer.

Allowed ranges are compared as networks, so `10.0.0.1/24` and `10.0.0.2/24` collide while nested prefixes such as `10.9.0.0/16` and `10.9.1.0/24` do not. No peer may claim the server's own address as a host route.

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
| `WG_IFACE` | | `wg0` | Interface name (alphanumeric, `-`, `_`, at most 15 characters, starting with a letter or digit). `all`, `interfaces` and `default` are reserved |
| `WG_DNS` | | - | DNS servers and/or search domains, comma-separated (e.g. `1.1.1.1,8.8.8.8`). At least one server is required |
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
| `WG_ADDRESS` | | `10.77.0.2/32` | Interface address(es). Comma-separated, supports IPv4, IPv6, and dual-stack |
| `WG_PORT` | | - | UDP listen port (1-65535). If unset, the kernel picks a free port |
| `WG_IFACE` | | `wg0` | Interface name (alphanumeric, `-`, `_`, at most 15 characters, starting with a letter or digit). `all`, `interfaces` and `default` are reserved |
| `WG_ALLOWED_IPS` | | `10.77.0.1/32` | Routes to send through the tunnel. Use `0.0.0.0/0` for a full tunnel |
| `WG_KEEPALIVE` | | `25` | PersistentKeepalive in seconds (1-65535) |
| `WG_PSK` | | - | Pre-shared key |
| `WG_PSK_FILE` | | - | Path to file containing the PSK |
| `WG_DNS` | | - | DNS servers and/or search domains, comma-separated. At least one server is required |
| `WG_MTU` | | - | Interface MTU (1280-9000) |
| `WG_TABLE` | | - | Routing table: `auto`, `off`, or a numeric table ID (1-4294967295) |
| `WG_PRE_UP` | | - | Shell command to run before the interface comes up |
| `WG_POST_UP` | | - | Shell command to run after the interface comes up |
| `WG_PRE_DOWN` | | - | Shell command to run before the interface goes down |
| `WG_POST_DOWN` | | - | Shell command to run after the interface goes down |

¹ One of `WG_PRIVATE_KEY` or `WG_PRIVATE_KEY_FILE` is required.

## Notes

- Hook commands (`PRE_UP`, `POST_UP`, `PRE_DOWN`, `POST_DOWN`) run as root inside the container. Use `%i` as a placeholder for the interface name (substituted by wg-quick).
- The server healthcheck verifies that the interface exists and carries a key. The client healthcheck additionally checks for a recent peer handshake (≤ 185 s, or `WG_KEEPALIVE` + 125 s once the keepalive exceeds 60 s, since a longer keepalive stretches the interval between handshakes).
- The container logs the initial peer connection state after 30 s and any subsequent changes (full connectivity, partial, or disconnected).
- A `WG_*` variable set to an empty value is an error, not an omission: Compose writes a missing `.env` entry into the container as an empty string, and reading that as "unset" would drop a `WG_PSK`. Leave the variable out instead.
- `WG_SERVER_ENDPOINT` is resolved once, when the interface comes up. If the server's address changes behind a hostname, the client keeps sending to the old one and goes unhealthy; Docker does not restart on unhealthy, so that needs a `docker restart` (or a watchdog).
- **Secrets:** a value passed as an environment variable stays readable in `docker inspect` and `/proc/<pid>/environ` for the container's whole lifetime. The `*_FILE` variants avoid that, see [`examples/secrets.yaml`](examples/secrets.yaml).
- **IP forwarding** is a host kernel setting, not a container setting. If the server routes traffic between peers (full tunnel with `WG_ALLOWED_IPS=0.0.0.0/0`, or client-to-client as in the multi-client example), enable it on the host: `sysctl -w net.ipv4.ip_forward=1` (persist via `/etc/sysctl.conf` or `/etc/sysctl.d/`). The iptables `FORWARD` rules in the examples are not sufficient on their own.
- **Full tunnel** clients need one more host setting: `sysctl -w net.ipv4.conf.all.src_valid_mark=1`. For a `0.0.0.0/0` route wg-quick sets this itself, but `/proc/sys` is read-only inside a container, so the write fails and takes wg-quick down with it. Set on the host, wg-quick skips it.
- **A hook is one shell command.** When a `PostUp` fails, wg-quick removes the interface without running `PostDown`, so whatever ran before the failure stays on the host. Put the fragile part first, as the full-tunnel example now does.
- Two containers must not share one bind-mounted `/etc/wireguard` under the same `WG_IFACE`: the config is named after the interface, so the second to start overwrites the first. A start that fails leaves an existing config alone.
- With `network_mode: host` the WireGuard interface lives in the host's network namespace and outlives a container that was killed rather than stopped. On start compwire reclaims such an interface if it carries its own public key, and refuses to start if the interface belongs to anything else.
- With `network_mode: host`, all services in the same Compose file share the host network stack and therefore need distinct `WG_IFACE` values (e.g. `wg0`, `wg1`, `wg2`). Clients don't bind a fixed port unless `WG_PORT` is set; multiple servers additionally need distinct `WG_PORT` values. They also share one routing table: two clients of the same server both want a route to its tunnel address, and the second one fails with `RTNETLINK answers: File exists`. A server plus one client works, two clients need two hosts. In production each node runs on its own host, so this does not apply.

---

## License

[BSL 1.1](LICENSE) - free for personal and non-commercial use.
