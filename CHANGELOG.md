# Changelog

All notable changes to this project are documented in this file, in the format of [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.0.2] - 2026-10-24

### Changed

- Every Alpine patch is followed by a compwire patch release with the latest package fixes.

### Dependencies

- alpine 3.24 -> 3.24.3

## [1.0.1] - 2026-09-17

### Changed

- The license is GPL-3.0-only instead of the Business Source License 1.1.

### Removed

- The `compose.yml` in the repository root. The README and the examples have the compose files.

### Security

- The private key reaches the disk only after every check has passed.

## [1.0.0] - 2026-08-13

### Breaking changes

- The `showqr` command is gone. Set up a phone by hand with the values a client container would get.
- A misspelled `WG_PEER_*` variable, an unknown command or an empty key file stops the start instead of being ignored.
- Two peers with the same key or the same allowed network stop the start.

### Added

- `genpsk` prints a pre-shared key.
- An example that passes every key as a Docker secret.
- A tunnel left behind by a killed container is taken over on the next start.
- A warning for a `WG_*` variable the container does not read, such as a typo.
- Warnings for settings that start but carry no traffic.
- More checks of keys, addresses, endpoints, interface names and DNS before the tunnel starts.

### Changed

- The client healthcheck follows `WG_KEEPALIVE`.
- The healthcheck needs a key on the interface, not just a device of that name.
- A failed start names the usual causes.
- The full tunnel example needs `WG_OUTBOUND_IFACE` set and routes IPv4 only.

### Fixed

- `docker stop` during startup waited for the full timeout.
- A container with `WG_DNS` did not start.
- `WG_DNS` was lost after a hard kill and a restart.
- A failed start could wipe the config of a running tunnel in a shared `/etc/wireguard`.
- A client stuck on resolving its endpoint showed as healthy.
- A full tunnel failed on hosts without the iptables compatibility modules. The image ships nftables now.
- Huge numbers for ports, MTU, prefixes and keepalive passed the checks.
- A trailing comma in an address list went unnoticed.
- An endpoint with text after the port was accepted.
- One IPv6 address with two prefix lengths was refused in allowed IPs.
- A tunnel left without a key by a kill could not be taken over.
- The second client in the multi-client example got the address of the first.
- The full tunnel example left firewall rules behind after a failed start.
- A prerelease could move the `latest` image tag.

### Security

- `docker build` in the repository no longer sends `.env` and `secrets/` to the Docker daemon.
- Hook commands no longer see the pre-shared keys of peers.
- The config file is private from the moment it is created.
- The compose files drop every capability but `NET_ADMIN`.
- `.gitignore` covers the `.env` and the key files the examples ask for.

## [0.2.0] - 2026-07-14

### Added

- Malformed keys, addresses and peer IDs stop the start.

### Changed

- A client only listens on a fixed port when `WG_PORT` is set.

### Fixed

- Server and client on one host both tried to use port 51820.

## [0.1.3] - 2026-06-10

### Dependencies

- alpine 3.23 -> 3.24 (#4)

## [0.1.2] - 2026-05-19

### Changed

- Peers are sorted naturally, so `CLIENT2` comes before `CLIENT10`.

### Fixed

- A line break in an endpoint or a hook could add settings to the config.
- `WG_DNS` only takes addresses and host names.
- A key file with trailing spaces or tabs broke the config.
- A signal during startup could get lost.

## [0.1.1] - 2026-05-15

### Added

- The image is on Docker Hub as well (#1).

## [0.1.0] - 2026-05-14

### Added

- WireGuard as server or client in a small Alpine image, set up with environment variables.
- A server takes several peers, each with its own allowed IPs, pre-shared key, endpoint and keepalive.
- Keys can come from files.
- `genkey` prints a key pair, `showqr` a QR code for the phone apps.
- A healthcheck, and a log line when a peer connects or drops.
- Examples for a basic setup, several clients, a full tunnel and an IPv6 endpoint.

[Unreleased]: https://github.com/ivenos/compwire/compare/v1.0.2...HEAD
[1.0.2]: https://github.com/ivenos/compwire/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/ivenos/compwire/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/ivenos/compwire/compare/v0.2.0...v1.0.0
[0.2.0]: https://github.com/ivenos/compwire/compare/v0.1.3...v0.2.0
[0.1.3]: https://github.com/ivenos/compwire/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/ivenos/compwire/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/ivenos/compwire/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/ivenos/compwire/releases/tag/v0.1.0
