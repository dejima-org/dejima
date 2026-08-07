# Development

[← dejima README](../README.md)

The file-by-file map of this repository, and the detail behind its test
suites: what each one covers, whether it needs a Docker daemon, and how to
run them.

## Files

| File | Purpose |
| --- | --- |
| `docker/Dockerfile` | Base image, dev tools, nvim, Claude Code + wrapper, `gitea-pr`/`gitea-issue` |
| `docker/fixed-domains.sh` | Shared domain list sourced by both `init-firewall.sh` and `dns-proxy.sh` |
| `docker/dns-proxy.sh` | Starts the DNS-allowlisting `dnsmasq`, repoints `resolv.conf` at it |
| `docker/init-firewall.sh` | IPv4/IPv6 egress allowlist firewall, run at container start |
| `docker/ulogd.conf` | `ulogd2` config: turns `init-firewall.sh`'s NFLOG-tagged packets into JSON |
| `docker/log-shipper.sh` | Tails the dnsmasq/ulogd2 logs and ships them to the configured Loki endpoint (`[logging] loki_url`); also ships session transcripts when conversation logging (`[logging] conversation`) is on |
| `docker/entrypoint.sh` | Runs as root: DNS proxy, firewall, logging, drops to the sandbox user via `gosu`, then execs the session's command |
| `docker/claude-wrapper.sh` | Shadows `claude` on `PATH` to always add `--dangerously-skip-permissions` |
| `docker/docker-compose.yml` | Wires up mounts/env; invoked via `bin/dejima`, not directly |
| `hooks/sandbox-context.sh` | `SessionStart` hook: injects sandbox context/workflow reminders, and any `.dejima.md` the project ships |
| `.dejima.md` | Project-level agent instructions, harness-agnostic: `CLAUDE.md`'s role under a neutral name. dejima loads a project's into the session context; this one is dejima's own |
| `hooks/git-push-guard.sh` | `PreToolUse` hook: blocks pushes outside the allowed host(s)/branches |
| `hooks/deny-dangerous-bash.sh` | `PreToolUse` hook: blocks obviously destructive Bash commands |
| `hooks/merge-guard.sh` | `PreToolUse` hook: blocks the configured forge's merge command (`DEJIMA_MERGE_BLOCK`) in the sandbox: merging is a human decision |
| `hooks/dejima-notify.sh` | `Notification`/`Stop` hook: drops an empty `waiting`/`done` marker for a remote-enabled session - see [docs/remote-access.md](remote-access.md) |
| `bin/dejima-attach` | Lists live sessions and attaches to one; the shared core behind both remote front doors |
| `bin/dejima-audit` | Advisory exit-time diff of host-persistence surfaces (git config, `.claude/`, etc.). `dejima-audit show` / `dejima-audit ack` default to the enclosing repo |
| `bin/dejima-dep` | Review and approve project dependencies declared in `.dejima/dependencies` |
| `bin/dejima-provider-lib.sh` | Parses forge/workflow/harness manifests and composes the session briefing; not on PATH: see [docs/providers.md](providers.md) |
| `forges/`, `workflows/`, `harnesses/` | Provider directories for the three axes selected by `[core] forge`/`workflow`/`harness` (data, never sourced or executed); see [docs/providers.md](providers.md) |
| `forges/gitea/bin/` | The gitea forge's own CLIs, baked into the image so the sandbox can act on them: `gitea-pr` (create a PR, read its comments, merge it), `gitea-issue` (list, view, create, comment on, close and reopen issues) and `gitea-actions` (read CI runs and job logs) |
| `bin/dejima-notify-watch` | Host-side watcher: turns markers into ntfy pushes composed entirely from host data |
| `bin/dejima-project` | Review and approve project domains and dependencies from the host |
| `bin/dejima-project-lib.sh` | Shared library sourced by `bin/dejima-dep`, `bin/dejima-project`, `bin/dejima` and the remote-access scripts; not on PATH |
| `bin/dejima-ttyd` | Launches `ttyd` on loopback in front of `dejima-attach` |
| `systemd/*.service` | User units for `dejima-ttyd` and `dejima-notify-watch`; ship disabled, installed by hand |
| `docs/providers.md` | The manifest contract for the forge/workflow/harness axes, key by key, with the shipped manifests as worked examples |
| `docs/ci.md` | What push access grants a session on your CI host, and how to bound it - runner hardening, and an egress allowlist read from `main` |
| `ci/` | Worked runner, resolver and firewall examples for the setup `docs/ci.md` describes; installed by nothing, and belongs on a CI machine rather than a dejima one |
| `docs/nginx-dejima.conf.example` | Reverse-proxy template for the web front door; deliberately not loadable as written |

`bin/dejima` is the entry point: it resolves the project path,
checks for a live `ssh-agent`, reads `GITEA_TOKEN`/`GH_TOKEN` from the token
files named in the config, discovers which host directories need mounting for symlinks under
`~/.claude` (`hooks`, `skills`, `commands`, `agents`, `output-styles`, and
top-level entries like `statusline.sh`) to resolve, and runs
`docker compose run`. `bin/dejima-allow`
adds a domain to a running session's firewall from the host - see "Adding a
domain to a running session" in the README. `install.sh` installs the hooks into
`~/.claude/hooks` and registers them in `~/.claude/settings.json`.

## Tests

`test/` has a [bats](https://github.com/bats-core/bats-core) suite covering
the security invariants the README states, not a substitute for reading it,
but a way to actually catch a future change silently breaking one of them
instead of finding out the hard way.

`static.bats` greps the repo's own files - no sudo in the `Dockerfile`, every
`ipset add` is duplicate-safe, no `docker.sock`/host-credential mounts, the
`~/.claude` mount inventory is exactly what it should be, `dejima-allow`
rejects a malicious domain argument. `runtime.bats` builds the image, boots
a real container running the actual `entrypoint.sh` (a `SANDBOX_TEST_MODE`
env var makes it stop just short of execing the session's command, so the suite can attach
to a fully-initialized container instead of reimplementing its own copy of
the setup sequence), and asserts against it: IPv6 blocked, DNS/IP allowlist
enforcement in both directions, GitHub read-only, no working `sudo`/
`iptables`/`init-firewall.sh` as `node`, capabilities actually stripped
(not just absent from a `docker exec` that doesn't have them to begin
with), `ulogd2` unprivileged, and the dynamic-ipset CDN-rotation fix.

`project.bats`, `remote.bats` and `audit.bats` need no Docker either.
`project.bats` covers the
declaration/approval split - what `.dejima/` may ask for, what only the host
can grant, and that the approval store is never mounted. `remote.bats`
covers everything in [docs/remote-access.md](remote-access.md):
the `[remote-access]` config section, the session registry, and the properties the
feature's security rests on - that the
notification path carries no sandbox-controlled byte, and that no marker
name outside `waiting`/`done` is ever acted on. `audit.bats` covers
`bin/dejima-audit`'s own diffing.

`config.bats`, `providers.bats` and `proxy.bats` round out the suites that
need no Docker either: `config.bats` covers `~/.config/dejima/config`
parsing and `install.sh`'s legacy-variable warnings (stubbing `docker` itself,
since the fast CI job's container deliberately has no daemon), `providers.bats`
covers the forge/workflow/harness manifest contract documented in
[docs/providers.md](providers.md), and `proxy.bats` covers the credential
proxy's own request handling.

One assertion is worth calling out because it can only run for real on a
Docker host: `runtime.bats` proves that a service bound to the host's
loopback is unreachable from inside a container while one bound to the
bridge gateway *is* reachable. The second half is a positive control - it is
what stops the first from passing in an environment where the container
simply reaches nothing. That pair is the ttyd front door's whole containment
argument, so run it before trusting a front door you just set up.

Every mutation in `runtime.bats` (firewall rules, `ipset` entries) happens
inside the test container's own network namespace, same as any other
container - none of it touches the host. Container/network names are
derived from bats' own per-run temp directory, not anything guessable or
likely to collide with a real container you have running.

`ci-runner.bats` is different in kind from the others: it doesn't test
this repository at all, it asserts on the CI runner executing it (the Docker
socket withheld from the sandbox job, granted to the host-docker job, and
the egress each is allowed) - see [docs/ci.md](ci.md). It skips outright
unless `DEJIMA_CI_TIER` is set, so it has nothing to say when run locally.

### Running the tests

```sh
bats test/               # everything
bats test/audit.bats     # one suite - the suites are independent, see .dejima.md
SKIP_BUILD=1 bats test/runtime.bats   # the one suite needing Docker; reuse the current image
```

`runtime.bats` is the only suite that needs a Docker daemon: it is the one
that builds the image and boots real containers to assert against.
Everything else, `audit.bats`, `ci-runner.bats`, `config.bats`,
`project.bats`, `providers.bats`, `proxy.bats`, `remote.bats` and
`static.bats`, runs anywhere a shell does, including inside a dejima sandbox
itself, which has no Docker daemon by design.

`.gitea/workflows/tests.yml` runs all of it on every pull request and on every
push to one, `runtime.bats` included. That job needs two things from the
runner that an ordinary one doesn't (the host's Docker socket and the host
network namespace), and it checks for both up front rather than failing
obscurely partway through; the file says why each is needed.
