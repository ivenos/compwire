# Contributing

## Setup

There is nothing to build. The project is `entrypoint.sh` plus the image that
wraps it. You need `shellcheck` to lint and Docker to run the integration
tests.

## Tests

Unit tests run anywhere. They mock `wg` and `wg-quick` and only verify the
generated config, so neither Docker nor a WireGuard kernel module is needed:

```bash
sh test/run_tests.sh
```

Your `/bin/sh` is probably not the image's, and some assertions only bite under
busybox ash. Run it there too; the two runs report different totals on purpose,
because the container is uid 0 and the permission cases skip themselves:

```bash
tar c entrypoint.sh Dockerfile test \
  | docker run --rm -i "$(awk '/^FROM /{print $2; exit}' Dockerfile)" \
      sh -c 'mkdir /w && cd /w && tar x && sh test/run_tests.sh'
```

Lint, the same three files CI checks:

```bash
shellcheck entrypoint.sh test/run_tests.sh test/integration_test.sh
```

Integration tests start real containers on a Docker bridge network and check
that peers reach each other. They need Docker, `NET_ADMIN` and a kernel with
WireGuard (5.6 or newer; run `modprobe wireguard` if the module is not
loaded):

```bash
docker build -t compwire:test .
sh test/integration_test.sh compwire:test
```

CI runs lint once and the unit suite twice, under the runner's shell and under
busybox ash, then the integration tests on amd64 and arm64, before anything is
published.

## Code style

- POSIX sh, no bashisms. The image ships busybox ash, so whatever shellcheck
  flags under `sh` is a real bug rather than a nit.
- Quote every expansion. Validate every environment variable before it reaches
  the config file: the values come from the user and end up in a file whose
  hook lines root executes.
- A comment only earns its place when it records something the code cannot: a
  wg-quick quirk, a kernel constraint, the reason for a non-obvious regex. One
  or two lines. Never restate what the code already says.

## Environment variables

Every knob is an environment variable, which makes a new one a four-part
change: the validation in `entrypoint.sh`, the line it writes to the config, a
case in `test/run_tests.sh` covering both an accepted and a rejected value, and
a row in the README table for its role, or for both roles. A variable that is
not in the README does not exist.

## Commits

Conventional Commits (https://www.conventionalcommits.org/en/v1.0.0/), with a
short imperative subject.

## Releases

A `v[0-9]+.[0-9]+.[0-9]+*` tag builds the multi-arch image and publishes it to
GHCR and Docker Hub; a release proper also moves `latest`, a prerelease such as
`v2.0.0-rc1` does not. Commits on `main` publish `dev`. The tag pattern is
deliberately narrow, because a tag the semver rules cannot name would push image
layers that never get one. The changelog lives in the
GitHub release notes, in Keep a Changelog style
(https://keepachangelog.com/en/1.1.0/). There is no CHANGELOG.md file.

## Dependencies

The Alpine base and the GitHub Actions stay on version tags, never commit SHAs
or digests. Renovate opens the bumps; keep them out of behaviour changes.

## Pull requests

- One concern per PR. Add tests for behaviour changes.
- `shellcheck` and both test suites must pass.
- Fill in the PR template, including the test plan (which role, which scenario,
  unit or integration) and the CLA checkbox.
