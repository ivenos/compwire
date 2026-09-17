# Contributing

## Build

There is nothing to compile. The project is `entrypoint.sh` and the image that wraps it:

```bash
docker build -t compwire:test .
```

## Tests

- Unit tests mock `wg` and `wg-quick` and check the generated config. They need neither Docker nor a WireGuard kernel module:

```bash
sh test/run_tests.sh
```

- Run them under the image's busybox ash as well. The permission cases skip themselves as root:

```bash
tar c entrypoint.sh Dockerfile test | docker run --rm -i "$(awk '/^FROM /{print $2; exit}' Dockerfile)" sh -c 'mkdir /w && cd /w && tar x && sh test/run_tests.sh'
```

- Lint:

```bash
shellcheck entrypoint.sh test/run_tests.sh test/integration_test.sh
```

- Integration tests start real containers on a Docker bridge network. They need Docker, `NET_ADMIN` and a kernel with WireGuard (5.6 or newer, `modprobe wireguard` if the module is not loaded):

```bash
sh test/integration_test.sh compwire:test
```

- CI runs lint, the unit suite under the runner's shell and under busybox ash, and the integration tests on amd64 and arm64 before anything is published.

## Code style

- POSIX sh, no bashisms. The image ships busybox ash.
- Quote every expansion. Validate every environment variable before it reaches the config file.
- A comment only earns its place when it records something the code cannot, such as a wg-quick quirk or a kernel constraint. One or two lines.

## Environment variables

- A new variable touches four places: the validation in `entrypoint.sh`, the line it writes to the config, a case in `test/run_tests.sh` with an accepted and a rejected value, and a row in the README table for its role.
- A variable that is not in the README does not exist.

## Commits

Conventional Commits (https://www.conventionalcommits.org/en/v1.0.0/) with a short imperative subject.

## Releases

- A `v[0-9]+.[0-9]+.[0-9]+*` tag builds the multi-arch image and publishes it to GHCR and Docker Hub. A release moves `latest`, a prerelease such as `v2.0.0-rc1` does not. Commits on `main` publish `dev`.
- The changelog lives in the GitHub release notes, in Keep a Changelog style (https://keepachangelog.com/en/1.1.0/). There is no CHANGELOG.md.

## Dependencies

- The Alpine base and the GitHub Actions stay on version tags, never commit SHAs or digests.
- Renovate opens the bumps. Other PRs leave dependencies alone.

## Pull requests

- One concern per PR, with tests for behavior changes.
- Only the PR author and the maintainer commit to it.
- `shellcheck` and both test suites must pass.
- Fill in the PR template, including the CLA checkbox.
