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

- Conventional Commits (https://www.conventionalcommits.org/en/v1.0.0/) with a short imperative subject.
- A commit that does more than one thing lists its changes in the body, under the changelog section names as plain words. Changes to CI and tests are listed there too:

```
Added
- genpsk prints a pre-shared key

Changed
- CI runs the unit suite under busybox ash

Fixed
- A trailing comma in an address list went unnoticed
```

## Changelog

- `CHANGELOG.md` follows Keep a Changelog (https://keepachangelog.com/en/1.1.0/), with `Breaking changes` as the first section and `Dependencies` as the last.
- Every commit that changes something for users adds its entry under `Unreleased`. CI, tests and refactoring stay out.
- An entry is one short sentence in plain words that anyone understands. Details belong in the README.
- What users have to act on after an update goes under `Breaking changes`.
- An entry that goes back to an issue or a pull request ends with its number: `(#12)`.

## Releases

- Run the Release workflow with the new version, such as `1.5.0`. It turns `Unreleased` into that version, tags the commit, publishes the image and builds a draft release with the notes from `CHANGELOG.md`.
- A tag pushed by hand publishes the image and builds the draft too, from the section of its version.
- A merged Alpine patch is released on its own as the next patch version, without a draft. If `Unreleased` lists more than dependencies, it waits for the next release.
- The image goes to GHCR and Docker Hub, for amd64 and arm64. A release moves `latest`, a prerelease such as `v2.0.0-rc1` does not. Commits on `main` publish `dev`.

## Dependencies

- The Alpine base and the GitHub Actions stay on version tags, never commit SHAs or digests. Alpine carries its full version, such as `3.24.3`, so Renovate sees every patch and merges it on its own.
- Renovate opens the bumps and adds each one to the changelog. The release adds the numbers of their pull requests. Other PRs leave dependencies alone.

## Pull requests

- One concern per PR, with tests and a changelog entry for behavior changes.
- Only the PR author and the maintainer commit to it.
- `shellcheck` and both test suites must pass.
- Fill in the PR template, including the test plan and the CLA checkbox.
