# Development

[← dejima README](../README.md)

The file-by-file map of this repository, and the detail behind its test
suites: what each one covers, whether it needs a Docker daemon, and how to
run them.

## Files

| File | Purpose |
| --- | --- |
| `docker/Dockerfile` | Base image: dev tools, nvim, Playwright, the sandbox user. Carries **no harness** - the selected one installs into a layer above it, from its manifest's `install` |
| `docker/install-forge-bins.sh` | Installs each forge's CLIs into the image from its manifest's `install` list, and fails the build on a file that is shipped but not declared, or declared but not shipped |
| `docker/fixed-domains.sh` | Shared domain list sourced by both `init-firewall.sh` and `dns-proxy.sh` |
| `docker/dns-proxy.sh` | Starts the DNS-allowlisting `dnsmasq`, repoints `resolv.conf` at it |
| `docker/init-firewall.sh` | IPv4/IPv6 egress allowlist firewall, run at container start |
| `docker/ulogd.conf` | `ulogd2` config: turns `init-firewall.sh`'s NFLOG-tagged packets into JSON |
| `docker/log-shipper.sh` | Tails the dnsmasq/ulogd2 logs and ships them to the configured Loki endpoint (`[logging] loki_url`). Container-side, because those files only exist there |
| `docker/entrypoint.sh` | Runs as root: DNS proxy, firewall, logging, drops to the sandbox user via `gosu`, then execs the session's command |
| `docker/harness-wrapper.sh` | Shadows the selected harness's command on `PATH` to add its no-confirm flags and dejima's settings layer. Named by no harness; `entrypoint.sh` links it into place |
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
| `bin/dejima-config-lib.sh` | The config file's schema, parser and value validators, plus the dependency-spec grammar. The base layer: it sources nothing, so everything else can source it. Not on PATH |
| `bin/dejima-provider-lib.sh` | Parses forge/workflow/harness manifests and composes the session briefing; not on PATH: see [docs/providers.md](providers.md) |
| `forges/`, `workflows/`, `harnesses/` | Provider directories for the three axes selected by `[core] forge`/`workflow`/`harness` (data, never sourced or executed); see [docs/providers.md](providers.md) |
| `forges/gitea/bin/` | The gitea forge's own CLIs, baked into the image so the sandbox can act on them: `gitea-pr` (create a PR, read its comments, merge it), `gitea-issue` (list, view, create, comment on, close and reopen issues) and `gitea-actions` (read CI runs and job logs) |
| `bin/dejima-notify-watch` | Host-side watcher: turns markers into ntfy pushes composed entirely from host data |
| `bin/dejima-project` | Review and approve project domains and dependencies from the host |
| `bin/dejima-project-lib.sh` | Shared library sourced by `bin/dejima-dep`, `bin/dejima-project`, `bin/dejima` and the remote-access scripts; not on PATH |
| `bin/dejima-conversation-ship` | Host-side: ships session transcripts to Loki when `[logging] conversation` is on. Reads them where they already are, so the session is not in the path of its own oversight log |
| `bin/dejima-epitaph` | Host-side: keeps the summary a session leaves when its context is compacted away, in a store nothing mounts. Run from `bin/dejima`'s exit trap |
| `bin/dejima-harness-lib.sh` | Loads the selected harness's plugin and provides the `emit_*` functions it declares through; the guarded-store refusal runs in `emit_mount`. Not on PATH |
| `bin/harness/<name>.sh` | One per supported harness: what dejima does for that harness that no manifest value could state. Trusted computing base, sourced by `bin/dejima` |
| `bin/dejima-color-lib.sh` | The colour and terminal-detection helpers the CLIs share. Not on PATH |
| `bin/dejima-slug-lib.sh` | The `~/.claude/projects` slug scheme and which slugs belong to a workspace; sourced by `bin/dejima` (what to mount) and `bin/dejima-epitaph` (whose transcripts to keep), so the two cannot disagree. Not on PATH |
| `bin/dejima-ttyd` | Launches `ttyd` on loopback in front of `dejima-attach` |
| `systemd/*.service` | User units for `dejima-ttyd` and `dejima-notify-watch`; ship disabled, installed by hand |
| `docs/providers.md` | The manifest contract for the forge/workflow/harness axes, key by key, with the shipped manifests as worked examples |
| `docs/ci.md` | What push access grants a session on your CI host, and how to bound it - runner hardening, and an egress allowlist read from `main` |
| `docs/threat-model.md` | What is assumed hostile, and where each layer's compromise stops. Carries the blast-radius table `docs/security.md` also shows; a static test keeps the two identical |
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
proxy's own request handling. `conversation.bats` runs
`bin/dejima-conversation-ship` against a real transcript and a real HTTP
endpoint standing in for Loki, and asserts on what arrives: that a session's
lines ship, that a torn line waits until it is whole, that a sibling project
whose directory name merely extends this one is not swept up with it, and
that neither the in-memory batch nor the unread tail is lost to the kill that
ends a session.

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
`conversation.bats`, `project.bats`, `providers.bats`, `proxy.bats`,
`remote.bats` and `static.bats`, runs anywhere a shell does, including inside
a dejima sandbox itself, which has no Docker daemon by design.

`.gitea/workflows/tests.yml` also runs `shellcheck` over every shell script in
the repo, as its own job. `test/shellcheck.sh` holds the file list, discovered
by shebang rather than enumerated, so a script added under `bin/`, `hooks/`,
`docker/` or a forge's `bin/` is covered the day it lands. The severity floor
and the two disabled checks are in `.shellcheckrc`, each with the reason
beside it.

`.gitea/workflows/tests.yml` runs all of it on every pull request and on every
push to one, `runtime.bats` included. That job needs two things from the
runner that an ordinary one doesn't (the host's Docker socket and the host
network namespace), and it checks for both up front rather than failing
obscurely partway through; the file says why each is needed.

## Adding a new harness

`[core] harness` picks a directory under `harnesses/`, and that harness's
manifest declares eleven keys (see [providers.md](providers.md)). The
inventory below is everything dejima does that is shaped by *which* harness is
selected: which parts are the manifest's, which are the plugin's, and
which are still written against Claude Code by name. Taken from a pass over
the tree, so each row names the file rather than describing a sketch - and a
row that says "in the plugin" is one a second harness supplies rather than one
it has to argue about.

### What a harness must be able to do

Support is per harness and deliberate. A supported harness gets the same
depth of integration Claude Code has - the same mounts, the same guards, the
same audit surfaces - so a harness is not a manifest someone drops in. That
is only possible if the harness can host what those protections need.

These are the requirements. A harness that fails one of the first five
cannot be supported, and that is a decision about the harness rather than a
gap in dejima.

| | Requirement | Why it is load-bearing |
| --- | --- | --- |
| **R1** | **Unattended execution.** A documented mode that runs tool calls without confirming each one. | The premise the project rests on. A harness that stops to ask is one an operator sits in front of, and the argument for accepting that mode is that the container makes being unattended survivable. |
| **R2** | **Tool-call interception.** A supported mechanism to inspect a command before it runs and refuse it, without patching the harness. | The push guard, the merge guard and the dangerous-command denylist all live here. They are guards against an eager agent rather than a boundary against a hostile one, but a harness without them ships three protections short and the operator cannot add them back. |
| **R3** | **Host-controlled context at session start.** A way to place text into the session's context at start, from a file the operator controls and the session cannot rewrite for the run in progress. | How the briefing and the project's `.dejima.md` arrive. It is also how the agent learns it is sandboxed, which is what makes it ask for a domain instead of working around the firewall. |
| **R4** | **State dejima can locate or discard.** Per-project state must be computable on the host before launch, so it can be scoped per project - or safely discardable, so it can stay container-local. | #104. A store that is neither computable nor discardable cannot be scoped, and mounting it whole reintroduces cross-project context poisoning. |
| **R5** | **A withholdable credential.** The model credential must live somewhere dejima can decline to mount, and the harness must accept a substitute: a staged fake, or an environment variable pointed at the host-side proxy. | The credential never entering the container is a headline property, not a nicety. |

Three more are required, but may be declared absent in the manifest, in
which case dejima says at launch what is not in force:

| | Requirement | What is lost without it |
| --- | --- | --- |
| **D1** | Session lifecycle signals - something that fires when the agent wants attention and when it stops. | Remote access notifications. The session still runs and is still attachable. |
| **D2** | A parseable record of the session. | Epitaph, and conversation logging. |
| **D3** | An enumerable config directory whose extension points can be mounted read-only. | Config parity, and the read-only mounts that stop a session installing a persistent hook for the next one. |

Declaring one absent is a real decision with a visible cost, not a
formality. It is there so a harness can be supported honestly at a smaller
guard set rather than shipped with three protections quietly missing.

**The guard rails are declared in the manifest and reported at launch.**
`guards` lists which of `bash-deny`, `push-guard`, `merge-guard` and
`notify` the harness can host. A name outside that set is refused, because a
typo would otherwise turn a guard off in silence. The ones a harness does
not declare are named once at launch, with what each costs - and nothing is
printed at all when it hosts them all, so the message stays a signal rather
than a line to scroll past.

Core gates the work on the declaration rather than on whether a plugin
happens to define the hook: a harness that forgot to declare a guard but
implemented it would otherwise get a protection the launch message has just
told the operator it does not have.

### Worked example: why aider is not supported

aider clears R1 (`--yes-always`), R3 (`--read` places a file in context),
R4 (its state is `.aider.*` inside the workspace, which is already mounted)
and R5 (it takes an API key from the environment).

It fails **R2**. aider has no hook or event system; the only occurrence of
"hook" in its options is `--no-verify`, which controls git's own pre-commit
hooks. There is no supported point at which a command can be inspected and
refused, so `git-push-guard.sh`, `merge-guard.sh` and
`deny-dangerous-bash.sh` have nowhere to live and no equivalent to be
rebuilt from. It also fails D1.

The container would still bound an aider session. But three guards an
operator gets everywhere else would be missing with no way to restore them,
and "supported" would mean something different for that one harness than
for every other. So it is not supported, and this is the reason.

### Where a harness's support lives: three tiers

| Tier | What | Rule |
| --- | --- | --- |
| **Core** | the mechanism, and every enforcement point | harness-agnostic, always |
| **Manifest** | `harnesses/<name>/harness.conf` | data. Never sourced, never executed. Selects among named core mechanisms and supplies paths |
| **Plugin** | `bin/harness/<name>.sh` | the harness-specific remainder, as code, in this repository |

**A feature belongs in the manifest if it can be stated as a value.** It only
moves to a plugin when it cannot. `projects_dir` and `file_history_dir` are
both paths, so both are manifest keys; the rule that a *name* in the first
selects an *entry* in the second is Claude Code's own and could not be
written as a value, so that is the plugin. "Add a manifest key" is the
answer until it demonstrably is not.

**Plugins live under `bin/`, not beside the manifest.** `dejima-audit`'s
`tcb_snapshot` covers `install.sh`, `bin/`, `hooks/`, `docker/` and `test/`,
and not the provider directories. Host-side plugin code under `harnesses/`
would be code that runs on the host and that a session could edit in
dejima's own checkout without raising a CRITICAL - the exact class the audit
exists to catch. Under `bin/` it is covered for free, and "manifests are
data, never executed" stays true word for word.

**Plugins are sourced, not invoked**, and are part of the trusted computing
base. The risk worth designing against is not a careless plugin but three
plugins implementing the security model three ways, so a plugin uses core's
own primitives rather than re-deriving them. An invoked protocol would also
put a new text parser on the launch path, and every parsing bug this
repository has had is in that family.

**The manifest may carry values that are only used as paths or compared as
data. It must not carry text that becomes part of a parser's grammar, or the
identity of a security surface.** `dejima-audit`'s `ack` recovers a finding's
id by stripping a fixed label from the front of the finding text, anchored
deliberately (#45). Those labels are grammar. Provider directories are not in
`tcb_snapshot`'s list, so in the self-mount case a session can edit a
manifest without raising a CRITICAL - which is why host-execution surfaces
are a plugin hook (`harness_host_exec_surfaces`) rather than a manifest key.
The label stays a literal in code the audit watches; it just lives with the
harness that owns it.

**A plugin computes; core enforces.** A plugin declares through `emit_mount`
and `emit_env`, which validate at the point of declaration - `emit_mount`
runs the guarded-store refusal there, so a harness state directory that
overlapped the approval, audit or epitaph store is refused without each
plugin having to remember. A plugin never touches `extra_mounts` itself, and
a static test holds that. A plugin may *classify* an audit path; it may never
suppress a finding.

Every shipped harness has both a manifest and a plugin - a static test
refuses one without the other, because a manifest alone would present as a
supported harness while none of the work had been done.

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
`bin/dejima-audit` (twice) and `bin/dejima-epitaph`. A static test holds
the rule.

It returns empty when no harness is selected. `bin/dejima` refuses to start
in that state, so that is reachable only from the standalone tools, where a
harness-specific path resolving to nothing is the honest answer.

### The inventory

| Area | What is Claude Code specific | Where |
| --- | --- | --- |
| Install | which package installs the harness is the manifest's `install`, a dependency spec. That the image carries the selected harness **and no other**, that it is a layer keyed on the harness's name rather than part of the shared base, and that the spec is validated before it reaches a `RUN` line, are core's | `harnesses/<name>/harness.conf`, `bin/dejima` |
| Permission bypass | the flag itself, `no_confirm_args` in the manifest; the wrapper is generic | `harnesses/<name>/harness.conf` |
| Settings layering | that overrides arrive as an extra layer rather than a mount over the operator's file (#47) is core, as is the throwaway file itself; what the layer SAYS is the plugin's, written by `harness_prepare_config` - a settings schema is a parser's grammar, so a manifest cannot carry it. The flag that carries them is `settings_args` in the manifest | `bin/harness/claude-code.sh`, `harnesses/<name>/harness.conf` |
| Config preconditions | which config files must exist before staging, and which unusable one refuses the launch (Claude Code ignores an unparseable `settings.json` wholesale, with only a warning). Declared and enforced by the plugin, in the same hook | `bin/harness/claude-code.sh` |
| State directories | which directories must exist in the sandbox user's home, 0700 and owned by them, so Docker does not create a mount's missing parent root-owned. The manifest's `image_dirs`, created in that harness's own image layer | `harnesses/<name>/harness.conf` |
| Seeded files | that a harness reading a credential from a fixed path needs something at it, since an absent file and an empty one are not reliably the same to it. The manifest's `image_files`, created empty and 0600 in that harness's layer, where a mounted credential shadows it - rather than by `entrypoint.sh`, which runs in every image including the base one alone | `harnesses/<name>/harness.conf` |
| Image environment | anything the harness wants set for every session of its own - for Claude Code, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`. The manifest's `image_env`, in the same layer | `harnesses/<name>/harness.conf` |
| Command | there is no default anywhere shared. `SANDBOX_CMD` comes from the manifest's `command` via `bin/dejima`, and `entrypoint.sh` refuses an empty one rather than naming a harness a given image may not contain | `harnesses/<name>/harness.conf`, `docker/entrypoint.sh` |
| Proxied endpoint | which name the in-container TLS terminator answers for, and what `/etc/hosts` pins to loopback. The manifest's `proxied_api_domain`; a credential proxy with no domain declared is refused rather than started answering for nothing | `harnesses/<name>/harness.conf`, `docker/entrypoint.sh` |
| Egress allowlist | `platform.claude.com` always, `api.anthropic.com` only when no credential proxy is in front of it. `api_domains` and `proxied_api_domain` in the manifest | `harnesses/<name>/harness.conf` |
| Credentials | the whole proxy exists because Claude Code authenticates from `~/.claude/.credentials.json` rather than an env var; the entrypoint seeds a well-formed fake so it has something to read | `bin/dejima-anthropic-proxy`, `docker/anthropic-proxy-forwarder.js`, `docker/entrypoint.sh` |
| Hook protocol | the event payload arrives on stdin; `SessionStart` returns `hookSpecificOutput.hookEventName`/`additionalContext` as JSON, while a `PreToolUse` hook blocks by exiting 2 with its reason on stderr | `hooks/*.sh` |
| Hook registration | four hooks written into `~/.claude/settings.json` in Claude Code's schema, one `SessionStart` with a `startup\|resume\|clear\|compact` matcher and three `PreToolUse` matching `Bash`. In the plugin, gated per declared guard | `bin/harness/claude-code.sh` |
| Briefing delivery | the briefing and the project's `.dejima.md` reach the session *through* the `SessionStart` hook. No hooks, no briefing | `hooks/sandbox-context.sh` |
| Notifications | `Notification`/`Stop` hooks, registered per session into the settings layer, are what drop the markers remote access watches | `hooks/dejima-notify.sh`, `bin/dejima` |
| Config parity | which directories carry over and at what mode. Declared by the plugin, since `docker-compose.yml` is static YAML and could only name one harness's | `bin/harness/claude-code.sh` |
| Staged config | which files are copied rather than mounted. Declared by the plugin; the staging tree mirrors the destination, so `entrypoint.sh` names no harness's paths | `bin/harness/claude-code.sh` |
| App state | `~/.claude.json` is copied rather than mounted, because it mixes live state with `mcpServers` config | `bin/dejima` |
| State layout | the project key - cwd with every non-alphanumeric replaced by `-` - is Claude Code's scheme, and dejima reproduces it in four places | `bin/dejima-slug-lib.sh`, `bin/dejima-project-lib.sh`, `docker/log-shipper.sh` |
| Per-project scoping | `projects/` is mounted one slug at a time and `file-history/` one session at a time, the second resolved by pairing `projects/<slug>/<id>.jsonl` with `file-history/<id>` (#104). In the plugin | `bin/harness/claude-code.sh` |
| Transcript format | the transform from transcript lines to log lines. In the plugin; the shipping, batching and Loki labels stay core's | `bin/harness/claude-code.sh` |
| Compaction format | what a compaction looks like in a transcript. In the plugin; the store, its modes and the provenance note stay core's | `bin/harness/claude-code.sh` |
| Audit surfaces | `.claude/settings.json` is CRITICAL and the rest of `.claude/` is a WARNING, because that is where this harness keeps things that run | `bin/dejima-audit` |
| Host code execution | `statusline.sh` is audited as its own CRITICAL surface because `settings.json`'s `statusLine.command` runs it **unsandboxed on the host**. Declared by the plugin, since a finding's label is a parser's grammar rather than data | `bin/harness/claude-code.sh` |

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

**Every supported harness is a dependency of this project**, declared in
`.dejima/dependencies`, so a session working on dejima can run the one it is
integrating rather than reason about it. A harness dejima claims to support
and cannot exercise here is one whose guards are asserted rather than
observed - and an untested guard is worse than a declared-absent one,
because absent is visible to the operator and broken is not.

`claude-code` is no exception to that: it is declared by its own manifest and
built into its own layer like any other. The base image carries nothing of any
harness's - not its package, not the directories it keeps state in, not its
environment, and not its name as a default command. What is left on the
harness axis is the credential proxy, which is Claude Code's shape throughout
and is the R5 row above.

`providers.bats` covers the manifest contract itself and is where a new
`harness.conf` gets its parsing and validation tests. The suites that assert
on Claude Code paths by name - `config.bats`, `audit.bats`, `static.bats`,
`runtime.bats` - are the ones that will need a second set, and a green run
against the existing harness proves nothing about a new one. Nothing in
`test/` currently runs a second harness end to end.
