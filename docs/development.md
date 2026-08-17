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
| `bin/dejima-epitaph` | Host-side: keeps the summary a session leaves when its context is compacted away, in a store nothing mounts. Run from `bin/dejima`'s exit trap |
| `bin/dejima-slug-lib.sh` | The `~/.claude/projects` slug scheme and which slugs belong to a workspace; sourced by `bin/dejima` (what to mount) and `bin/dejima-epitaph` (whose transcripts to keep), so the two cannot disagree. Not on PATH |
| `bin/dejima-ttyd` | Launches `ttyd` on loopback in front of `dejima-attach` |
| `systemd/*.service` | User units for `dejima-ttyd` and `dejima-notify-watch`; ship disabled, installed by hand |
| `docs/providers.md` | The manifest contract for the forge/workflow/harness axes, key by key, with the shipped manifests as worked examples |
| `docs/ci.md` | What push access grants a session on your CI host, and how to bound it - runner hardening, and an egress allowlist read from `main` |
| `docs/nginx-dejima.conf.example` | Reverse-proxy template for the web front door; deliberately not loadable as written |

`bin/dejima` is the entry point: it resolves the project path,
checks for a live `ssh-agent`, reads `GITEA_TOKEN`/`GH_TOKEN` from the token
files named in the config, discovers which host directories need mounting for symlinks under
`~/.claude` (`hooks`, `skills`, `commands`, `agents`, `output-styles`, and
top-level entries like `statusline.sh`) to resolve, and runs
`docker compose run`. `bin/dejima-allow`
adds a domain to a running session's firewall from the host - see
[Adding a domain to a running session](security.md#adding-a-domain-to-a-running-session).
`install.sh` installs the hooks into
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
reaches nothing at all. That pair is the ttyd front door's whole containment
argument, so run it before trusting a front door you just set up.

Every mutation in `runtime.bats` (firewall rules, `ipset` entries) happens
inside the test container's own network namespace, same as any other
container - none of it touches the host. Container/network names are
derived from bats' own per-run temp directory, not anything guessable or
likely to collide with a real container you have running.

`ci-runner.bats` is different in kind from the others: it doesn't test
this repository at all, it asserts on the CI runner executing it (the Docker
socket withheld from the confined job, granted to the privileged job, and
the egress each is allowed) - see [docs/ci.md](ci.md). It skips outright
unless `DEJIMA_CI_TIER` is set, so it has nothing to say when run locally.

### Branches

Pull requests target `development`, which merges to `main` periodically, so
`main` stays releasable while work lands quickly. `gitea-pr` defaults its
base to the repository's default branch, so pass `--base development`.

CI needs no change for this: `.gitea/workflows/tests.yml` triggers on
`pull_request_target` with no branch filter, so it already runs whatever the
base is.

Nothing *enforces* the target. `git-push-guard.sh` blocks direct pushes to
the branches a workflow names, and that list is workflow-wide rather than
per-project - adding `development` would impose it on every dejima user,
most of whom have no such branch. So this is a convention with a check
attached: read what `gitea-pr` printed.

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

## Adding a new harness

`[core] harness` picks a directory under `harnesses/`, and a harness manifest
declares four things. Everything else dejima does for Claude Code is written
against Claude Code, and this is the inventory of it: what a second harness
has to supply, and where dejima has to stop assuming. Taken from a pass over
the tree, so each row names the file to change rather than describing a
sketch.

### The precondition

**The harness must have a way to run without asking permission per tool
call.** Claude Code's is `--dangerously-skip-permissions`, forced by
`docker/claude-wrapper.sh`, which shadows `claude` on `PATH` so an invocation
dejima never sees - an interactive shell, an editor plugin - still gets it.

This is the premise the whole project rests on, not a convenience. A harness
that stops to ask is one an operator has to sit in front of, and the argument
for accepting `--dangerously-skip-permissions` is that the container makes
being unattended survivable. A harness with no such mode can still be run,
but it is a different product and none of the reasoning in
[threat-model.md](threat-model.md) is about it.

### What the manifest already covers

`harnesses/<name>/harness.conf`, and the full contract is in
[providers.md](providers.md):

| Key | What it decides |
| --- | --- |
| `command` | the container's main process |
| `keys` | this harness's own `[harness.<name>]` config schema |
| `resume_command` | what the briefing tells a session to hand the operator |
| `briefing` | this harness's fragment of the session briefing |

### Reading a harness's own config

`harness_config_get <key>` resolves whichever harness `[core] harness`
names. Use it; do not spell a `[harness.<name>]` section out at a call site.

`keys` is declared per harness, so a literal section name makes it a
declaration only one harness can ever be read through - a second harness
gets selected, gets validated, and is then handed the first one's paths with
nothing erroring anywhere. Three call sites did exactly that, in
`bin/dejima-audit` (twice) and `bin/dejima-epitaph`. A static test now holds
the rule.

It returns empty when no harness is selected. `bin/dejima` refuses to start
in that state, so that is reachable only from the standalone tools, where a
harness-specific path resolving to nothing is the honest answer.

### The inventory

| Area | What is Claude Code specific | Where |
| --- | --- | --- |
| Install | `npm install -g @anthropic-ai/claude-code`, and a pinned `CLAUDE_CODE_VERSION` build arg | `docker/Dockerfile` |
| Permission bypass | the wrapper that shadows `claude` and forces the flag | `docker/claude-wrapper.sh` |
| Settings layering | sandbox overrides arrive as `--settings /etc/dejima-settings.json`, an extra layer rather than a mount over the operator's file (#47) | `docker/claude-wrapper.sh`, `bin/dejima` |
| Telemetry | `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` | `docker/Dockerfile` |
| Egress allowlist | `platform.claude.com` always, `api.anthropic.com` only when no credential proxy is in front of it | `docker/fixed-domains.sh` |
| Credentials | the whole proxy exists because Claude Code authenticates from `~/.claude/.credentials.json` rather than an env var; the entrypoint seeds a well-formed fake so it has something to read | `bin/dejima-anthropic-proxy`, `docker/anthropic-proxy-forwarder.js`, `docker/entrypoint.sh` |
| Hook protocol | the event payload arrives on stdin; `SessionStart` returns `hookSpecificOutput.hookEventName`/`additionalContext` as JSON, while a `PreToolUse` hook blocks by exiting 2 with its reason on stderr | `hooks/*.sh` |
| Hook registration | four hooks written into `~/.claude/settings.json` in Claude Code's schema, one `SessionStart` with a `startup\|resume\|clear\|compact` matcher and three `PreToolUse` matching `Bash` | `install.sh` |
| Briefing delivery | the briefing and the project's `.dejima.md` reach the session *through* the `SessionStart` hook. No hooks, no briefing | `hooks/sandbox-context.sh` |
| Notifications | `Notification`/`Stop` hooks, registered per session into the settings layer, are what drop the markers remote access watches | `hooks/dejima-notify.sh`, `bin/dejima` |
| Config parity | every `~/.claude` subdirectory is enumerated and mounted by name: `plugins`, `hooks`, `skills`, `commands`, `agents`, `output-styles` read-only; `backups`, `tasks`, `plans`, `sessions` read-write | `docker/docker-compose.yml` |
| Staged config | `settings.json`, `CLAUDE.md` and `statusline.sh` are staged read-only under `/etc/dejima-claude` and installed into place | `docker/entrypoint.sh`, `bin/dejima` |
| App state | `~/.claude.json` is copied rather than mounted, because it mixes live state with `mcpServers` config | `bin/dejima` |
| State layout | the project key - cwd with every non-alphanumeric replaced by `-` - is Claude Code's scheme, and dejima reproduces it in four places | `bin/dejima-slug-lib.sh`, `bin/dejima-project-lib.sh`, `docker/log-shipper.sh` |
| Per-project scoping | `projects/` is mounted one slug at a time and `file-history/` one session at a time, the second resolved by pairing `projects/<slug>/<id>.jsonl` with `file-history/<id>` (#104) | `bin/dejima`, `bin/dejima-slug-lib.sh` |
| Transcript format | conversation logging transforms Claude Code's JSONL line by line | `docker/log-shipper.sh` |
| Compaction format | epitaph keys on `isCompactSummary` records and the `compact_boundary` that precedes them | `bin/dejima-epitaph` |
| Audit surfaces | `.claude/settings.json` is CRITICAL and the rest of `.claude/` is a WARNING, because that is where this harness keeps things that run | `bin/dejima-audit` |
| Host code execution | `statusline.sh` is audited as its own CRITICAL surface because `settings.json`'s `statusLine.command` runs it **unsandboxed on the host** | `bin/dejima-audit`, `bin/dejima` |

### Two things worth deciding early

**What runs on the host when the harness is configured.** `statusLine.command`
is the one that exists today, and it is not a quirk: a harness that will
execute an operator-configured command outside the container hands a session
that writes that file a way onto the host. Find that surface in the new
harness before supporting it, because it belongs in the audit from the first
release rather than after someone finds it.

**What the harness keeps, and who else can read it.** The per-project
scoping of `projects/` and `file-history/` exists because a session that can
write another project's memory can plant text a later session there reads as
established background (#104). A new harness's state directory needs the same
question asked of it, one directory at a time. Anything mounted host-wide
should be there because it is keyed by session rather than by project, and
because nothing loads it into a session's context at startup - which is the
reasoning that leaves `tasks`, `plans`, `sessions` and `backups` mounted
whole today.

### Testing a new harness

`providers.bats` covers the manifest contract itself and is where a new
`harness.conf` gets its parsing and validation tests. The suites that assert
on Claude Code paths by name - `config.bats`, `audit.bats`, `static.bats`,
`runtime.bats` - are the ones that will need a second set, and a green run
against the existing harness proves nothing about a new one. Nothing in
`test/` currently runs a second harness end to end.
