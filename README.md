# buildx-3951-repro

Reproducer for [docker/buildx#3951](https://github.com/docker/buildx/issues/3951):
SSH agent forwarding (`--mount=type=ssh`) intermittently breaks in Bake builds.

## TL;DR

The issue blames `--allow=ssh` vs. answering `y` to the entitlement prompt. On
a closer look, **both modes fail intermittently**, at about the same rate. The
trigger is **two Bake targets that mount the SSH agent running at the same time
in one `bake` invocation.** In a failing run, one of the concurrent
`RUN --mount=type=ssh` steps (sometimes both) gets
`SSH_AUTH_SOCK=/run/buildkit/ssh_agent.0`, but the socket file doesn't exist in
its container. From `example-logs/fail-prompt-one-socket-missing.log`, where
the sibling step in the same build is fine:

```text
#18 1.280 srw------- 1 root root 0 Nov 20 08:48 /run/buildkit/ssh_agent.0
#18 4.515 [fetch-a] OK source = "git+ssh://git@github.com/rust-lang/cfg-if#14432a28..."
#20 0.649 ls: cannot access '/run/buildkit/ssh_agent.0': No such file or directory
#20 0.656 [fetch-b] ssh-add -l exit=2
#20 2.811 git@github.com: Permission denied (publickey).
```

A single SSH target never failed. It isn't specific to remote (`ssh://`)
contexts either: the local `docker` driver fails too.

## Layout

```text
final            no ssh; the requested target
├── fetch-a      ssh + `cargo fetch` of a git dependency (linked via contexts = "target:...")
└── fetch-b      ssh + `cargo fetch` of a git dependency (linked via contexts = "target:...")
      └── build-base   rust:1.95-slim-bookworm + git + openssh-client

simple           control: single ssh target doing a plain `git clone`
```

| Path | Purpose |
| --- | --- |
| `docker-bake.hcl` | Targets above, using `ssh = [{ id = "default" }]`. Only the SSH steps skip the cache (`no-cache-filter`), so repeated runs are quick. |
| `docker/shards/fetch.Dockerfile` | `fetch`: prints `SSH_AUTH_SOCK`, checks that the socket exists, runs `ssh-add -l`, then `cargo fetch` (`CARGO_NET_GIT_FETCH_WITH_CLI=true`). `clone`: plain `git clone`. |
| `repro.sh` | Runs `prompt` and `flag` modes N times per docker context, saves `--progress=plain` logs and an environment report to `logs/`, and prints a summary. |

The git dependency defaults to the public `rust-lang/cfg-if`, fetched over
`ssh://`. GitHub requires a registered key for SSH access even to public repos,
so this exercises agent forwarding without needing access to anything private.

## Requirements

- An SSH agent (`SSH_AUTH_SOCK`) holding a key registered on GitHub.
- `script(1)` (util-linux). The entitlement prompt only appears when stdin is a
  TTY, so prompt mode runs under a pseudo-terminal and answers `y`.

## Usage

```console
./repro.sh -n 5                               # current context, both modes, 5 runs each
./repro.sh -c remote-arm64 -c default -n 5    # several contexts
./repro.sh -m flag -n 10                      # --allow=ssh only
./repro.sh -t simple -m flag -n 10            # single-SSH-target control

# Another buildx binary, e.g. the version from the issue:
BUILDX=./bin/docker-buildx-v0.34.1 ./repro.sh -n 5

# Bake variables pass through, e.g. libgit2 instead of the git CLI in cargo:
GIT_FETCH_WITH_CLI=false ./repro.sh -n 5
```

`-c CONTEXT:LABEL` writes `LABEL` instead of the context name in logs and output.
The script exits non-zero if any run failed.

The logs are meant to be shareable. The environment report keeps only the
endpoint scheme of each context (no user, host or IP), and `ssh-add -l` output
keeps only key size and type (no fingerprints, no comments).

## Results

buildx v0.36.1, docker CLI 29.7.2, `final` target, default dependency, warm cache
(only the SSH steps re-run), modes interleaved. `example-logs/` holds two
failing runs, one passing run and the environment report.

| Context | Engine / BuildKit | Prompt (`y`) failed | `--allow=ssh` failed |
| --- | --- | --- | --- |
| `remote-arm64` (ssh://, arm64, docker driver) | 29.9.2 / v0.34.0 | 2/4 | 1/4 |
| `local` (unix://, amd64, docker driver) | 29.7.2 / v0.32.2 | 1/4 | 2/4 |

Control: `simple` (one SSH target) on `local`, `--allow=ssh`: 0/8 failed.

Every failure had the same signature: the agent socket was missing in one of
the two concurrent SSH steps, sometimes in both. A step that had the socket
always succeeded.

## Open questions

- Does it reproduce with two **independent** SSH targets (no shared `target:`
  context), or only when they share `build-base`?
- Does it need `cargo`, or do two concurrent `git clone` steps fail the same way?
- `docker-container` driver vs. `docker` driver, older buildx/BuildKit releases.
- Possible workaround: give each target its own SSH id (`ssh = [{ id = "a" }]`
  plus `--mount=type=ssh,id=a`), or serialize the SSH targets.
