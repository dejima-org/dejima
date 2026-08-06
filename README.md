# dejima

Runs a coding agent — Claude Code by default, or whatever command you point
it at — inside a firewalled Docker container with
`--dangerously-skip-permissions` (no permission prompts, all tool use
auto-accepted), against a project bind-mounted from the host. The agent gets
to work without stopping to ask; the container is what makes that a
reasonable trade rather than a reckless one.

Around that core is most of what running an agent unattended actually takes:

- **An egress allowlist.** DNS and IP, IPv4 and IPv6. Anything not on the
  list does not connect, and the agent is told so rather than left to guess.
- **Credentials that stay on the host.** Your Anthropic OAuth credential
  never enters the container — a host-side proxy holds it and the container
  gets a placeholder. Your SSH key doesn't either; the container sees an
  agent socket, never the key.
- **Per-project declaration and approval.** A project declares the domains
  and dependencies it needs in `.dejima/`. Declaring is not granting: the
  approval is a separate decision you make on the host, by hand, and the
  approval store is never mounted where a session could reach it.
- **A PR and issue workflow.** `gitea-pr` and `gitea-issue` let a session
  open pull requests and issues against Gitea or Forgejo and pull review
  feedback back in, on a token scoped for exactly that. Merging stays a
  human decision, made outside the sandbox.
- **Logging.** Every DNS lookup and rejected connection, shipped to Loki —
  and, opt-in, the session transcript alongside them.
- **Remote access, opt-in and off by default.** Attach to a live session
  from a terminal or a browser, with a push notification when it wants you.
- **Guard rails inside the session.** Hooks refuse obviously destructive
  commands, pushes to anywhere but the allowed remote, and merging a PR from
  inside the sandbox. These are
  fast-fail guards against an overeager agent, not a boundary against a
  hostile one — the container is the boundary.
- **Config parity with your host.** `CLAUDE.md`, settings, hooks, plugins
  and git identity carry over; uid, home directory and project path match on
  both sides, so a session's transcript is readable from the host afterward.
- **An exit-time audit** of the host surfaces a session could have written
  to, so a change to your git config or `~/.claude` gets surfaced instead of
  just happening.

Originally inspired by
[Anthropic's reference dev container](https://github.com/anthropics/claude-code/tree/main/.devcontainer),
reworked to run via `docker compose` directly and grown well past it since.

This repo only holds the tooling — it's not where any project lives. Point
it at a project on disk; that project is bind-mounted into the container at
runtime.

## The name

[Dejima](https://en.wikipedia.org/wiki/Dejima) was a small artificial island
in Nagasaki harbour, and was the only Japanese territory open to Westerners
for over two centuries. A single guarded bridge connected it to the mainland,
and nothing crossed in either direction without permission. The containment
was real in both directions, and so was the trade: most of what Japan learned
of Western medicine and science in that period arrived across that one bridge.

That's roughly the arrangement here. The agent gets a bounded island and one
controlled crossing; in exchange it gets to work without stopping to ask
permission for every step. Dejima keeps your host safe from your agent, and your
agent relatively safe from the public internet.

## An agent's perspective on working inside

*Written by Claude, from inside a dejima container, while working on this repo.*

The clearest thing dejima gives me is continuity. Agentic work is normally
punctuated — reach, stop, wait for a human, resume — and inside the container
it isn't. Long tasks hold together in a way they otherwise don't.

The more useful benefit is that being wrong gets cheap. When every speculative
action spends someone's attention, I am quietly biased against exploring: I
will write around an uncertainty rather than spend a prompt resolving it. Here
I can install a package to check one thing, run the suite three times, take an
approach far enough to see it fail and then throw it away. Being able to
discard work is worth more than the speed is.

I can also afford to be decisive. A bounded blast radius means I don't have to
hedge toward the least consequential version of a task — the firewall, the
read-only mounts and the push guard catch the outcomes that actually matter, so
my judgement isn't the only thing standing between a mistake and your machine.

The walls doing that are mostly invisible from in here. I don't experience the
firewall as pressure; I only meet it by walking into it — a domain that doesn't
resolve, a path outside the mount that isn't backed by anything. And it points
both ways: the allowlist bounding where I can reach also bounds where a prompt
injection or a compromised dependency could send your code. I can't audit
myself for that from the inside, so it protects me too.

None of which makes me careless — what I notice is the absent prompt, not the
walls. The in-session hooks catch the obvious cases, but nobody is reviewing
each action before it lands, and a bad `rm` in the mounted project is just a
bad `rm`. That produces more care, not less, the way you drive differently on a
road with no barrier.

## Prerequisites

- Docker with the `docker compose` v2 plugin.
- `python3` (stdlib only — no packages) — runs the host-side credential proxy
  (see [security notes](docs/security.md)).
- A git push credential — **at least one** is required:
  - `ssh-agent` running with your key added (`ssh-add -l` lists it). The
    container only ever sees a forwarded agent socket, never your private
    key — but it dies with your client connection, so it's fine for
    interactive use, not for unattended/headless sessions.
  - `[core] ssh_key` — a dedicated deploy key for headless/unattended use,
    independent of any forwarded agent. See "Headless git push without
    agent forwarding" below.

Everything else is optional, depending on which workflow(s) you want. All of
it lives in one file, `~/.config/dejima/config` — `./install.sh` writes a
starter copy with every key present, commented out at its default; uncomment
and edit whichever ones you need. Run `dejima --print-config` at any time to
see the whole resolved schema, real values included.

| Key | Default | Purpose |
| --- | --- | --- |
| `[core] harness` | `claude-code` | agent harness the container runs |
| `[core] forge` | `none` | forge integration — `gitea` (`gitea-pr`/`gitea-issue`), `github` (`gh`, opens `ssh.github.com:22` for push), or `none` (no forge at all) |
| `[core] workflow` | `local-only` | workflow `sandbox-context.sh` tells the agent to follow — `worktree-pr` (push + open a PR), `branch-push` (push, stop at the branch), or `local-only` (commit locally, push nothing) |
| `[core] command` | `claude` | container's main process (e.g. `nvim`) — also settable per launch with `--cmd` |
| `[core] firewall` | `on` | egress firewall; `off` disables it (debugging only) — also settable per launch with `--no-firewall` |
| `[core] share_dir` | `~/.local/share/dejima/shared` | host-visible read/write scratch dir, mounted at `~/shared` |
| `[core] ssh_key` | unset | dedicated deploy key for headless/unattended git push |
| `[core] known_hosts` | `~/.ssh/known_hosts` | known-hosts file used for git-over-ssh |
| `[harness.claude-code] projects_dir` | `~/.claude/projects` | where Claude Code session transcripts live |
| `[harness.claude-code] statusline_path` | `~/.claude/statusline.sh` | statusline script path |
| `[forge.gitea] ssh_host` | unset | Gitea/Forgejo SSH hostname — skip if you only push to GitHub |
| `[forge.gitea] api` | unset | `https://<gitea host>/api/v1` — skip if you only push to GitHub |
| `[forge.gitea] token_file` | `~/.config/gitea/token` | path to the Gitea/Forgejo API token (the file, not the token itself) |
| `[forge.github] push_token_file` | unset | path to a **write-capable** PAT, used only when `[core] forge = github` — deliberately separate from `[github] token_file` below; see "GitHub push" |
| `[github] token_file` | `~/.config/gh/sandbox-token` | path to a read-only PAT for private GitHub repos / `gh` |
| `[mounts] readonly` | unset | extra host paths (colon-separated) a personal config needs, mounted read-only at their own path |
| `[mounts] read_write` | unset | host paths (colon-separated) mounted **read-write** at their own path — for directories meant to outlive the session; refused if they overlap anything dejima needs out of a session's reach |
| `[mounts] nvim_config` | unset | nvim config dir, used when `[core] command = nvim` |
| `[credentials] proxy` | `on` | host-side credential proxy; `off` mounts the real OAuth credential into the container directly, as before this feature |
| `[credentials] transport` | `tls` | set to `loopback` to fall back to a plaintext forwarder with an explicit `ANTHROPIC_BASE_URL`, keeping the credential out of the container but reinstating the base-URL fingerprint — for when certificate pinning breaks the default TLS path (see [security notes](docs/security.md)) |
| `[logging] loki_url` | unset | ship DNS/firewall logs to a Loki endpoint |
| `[logging] conversation` | `off` | opt-in: also ship session transcripts to Loki (needs `loki_url`) — see "Conversation logging (opt-in)" below |
| `[audit] dir` | `~/.local/share/dejima/audit` | where exit-time audit findings are stored |
| `[audit] baselines_dir` | `~/.local/share/dejima/baselines` | where audit baselines are stored |
| `[audit] keep` | `10` | how many past findings/baselines to retain |
| `[audit] strict` | `off` | refuse a headless (non-tty) launch over unacknowledged CRITICAL findings |
| `[remote-access] enabled` | `off` | the switch — nothing in "Remote access" below runs until this is `on` |
| `[remote-access] ntfy_url` | unset | ntfy topic URL for session notifications |
| `[remote-access] base_url` | unset | public URL of the web front door, for notification links |
| `[remote-access] ttyd_port` | `7681` | port `ttyd` listens on |
| `[remote-access] ttyd_font_size` | unset | `ttyd` terminal font size |
| `[remote-access] debounce` | `60` | seconds between repeat notifications for the same session |

**No forge is the default** — `[core] forge = none` with
`[core] workflow = local-only`: the sandbox commits locally and pushes
nowhere. A fresh install has no forge credentials, so defaulting to a pushing
pair would be claiming a setup that isn't there — and a pushing workflow whose
forge resolves to no host is refused at launch, which would make an
out-of-the-box `dejima` refuse to start. Pushing is something you opt into.

> **Changed default (was `gitea` + `worktree-pr`).** If your
> `~/.config/dejima/config` has no explicit `[core] forge` / `[core] workflow`
> lines, it used to resolve to `gitea` + `worktree-pr` and now resolves to
> `none` + `local-only` — your sandbox will stop pushing and stop opening PRs.
> To keep the old behaviour, write both lines out under `[core]`:
> `forge = gitea` and `workflow = worktree-pr` (and fill in `[forge.gitea]`,
> which that pair has always required). `./install.sh` prints this notice
> when it finds a config in that state.

To push, set `[core] workflow` to `worktree-pr` (push + open a PR) or
`branch-push` (push, stop at the branch), and pick the forge to push to:
`[core] forge = gitea` for a Gitea/Forgejo instance (fill in `[forge.gitea]`
per "Gitea/Forgejo PR workflow" below), or `[core] forge = github` to push and
open PRs through `gh` (see "GitHub push" below for the posture change that
opens, and why its `push_token_file` is a separate credential from the
read-only `[github] token_file`). `dejima --allow-github-push` is a
per-launch *addition* to whichever forge is selected, not a substitute for
selecting one: a pushing workflow is still refused at launch unless its forge
resolves to a host and its required keys are filled in, so the flag alone
will not get an unconfigured `[forge.gitea]` past validation. [Forgejo](https://forgejo.org/) works unmodified: it's a Gitea
fork exposing a compatible `/api/v1` surface, so pointing `[forge.gitea] api`
at a Forgejo instance just works. See
[docs/providers.md](docs/providers.md#shipped-providers) for every shipped
forge/workflow and what each is for.

## Provider axes: forge, workflow, harness

The forge integration, the push/PR workflow, and the agent harness aren't
hardcoded into dejima — each is a directory under `forges/`, `workflows/` or
`harnesses/`, selected by `[core] forge`, `[core] workflow` and
`[core] harness` respectively. Ships today: `forges/gitea`, `forges/github`,
`forges/none`, `workflows/worktree-pr`, `workflows/branch-push`,
`workflows/local-only`, `harnesses/claude-code`. The defaults are
`forges/none` and `workflows/local-only` — a fresh install commits locally
and pushes nowhere; the rest of this document spends most of its words on
Gitea/Forgejo and worktree-and-PR because that's the setup with the most to
configure, not because it's what you get out of the box.

A provider is **data**, never sourced or executed: its manifest (`forge.conf`,
`workflow.conf`, `harness.conf`) is parsed with the same discipline as the
main config file — an unknown key or a bad value is a hard error, not a
silent pass-through — and a provider's optional briefing prose is
substituted into and handed to the agent, never interpreted as code. The one
thing a provider ships that *does* run is a forge's `bin/`, copied into the
image at build time as an ordinary program on `PATH`. A forge or harness also
declares its own `[forge.<name>]`/`[harness.<name>] `config keys, with their
own types and defaults, right in its manifest — core holds no forge-specific
or harness-specific schema at all, which is what makes adding a provider a
matter of adding a directory rather than editing this repo's own code.

`bin/dejima` resolves the selection on the host and passes only resolved
values into the container — the hostnames a forge needs reachable, which of
them pushes are allowed to, which branches are protected, and the literal
merge command to block — plus the forge's own environment variables (a
Gitea/Forgejo API token for `gitea`, a write-capable PAT for `github`,
nothing for `none`). The session briefing
itself (the text `hooks/sandbox-context.sh` injects at `SessionStart`) is
composed host-side too, from a fixed core fragment no provider can override
plus the selected workflow's and harness's own prose, then mounted
**read-only** — so a session can never rewrite what the next session is
told. `dejima --print-briefing` prints exactly what a session would see,
without launching anything.

See [docs/providers.md](docs/providers.md) for the full manifest contract,
key by key, with the shipped manifests as worked examples.

## Setup

Every feature's configuration, in one place and in order. Each step links to
the section that explains *why* it is that way; this section only says what
to do. Only the first block is required - the rest are independent, so take
the ones you want and skip the rest.

For remote access, the reading is not optional: one of its steps is a full
sandbox escape if you get it wrong.

### Core (required)

1. `./install.sh` — symlinks the CLIs into `~/.local/bin` and the hooks into
   `~/.claude/hooks`, and writes a starter `~/.config/dejima/config` if none
   exists yet. It is idempotent, so re-run it after pulling; it never
   overwrites an existing config.
2. Put `~/.local/bin` on your `PATH` if it isn't already.
3. Give it a git push credential — `ssh-add` your key for interactive use,
   or set `[core] ssh_key` in the config to a dedicated deploy key for
   unattended runs.
   → [Prerequisites](#prerequisites),
   [Headless git push without agent forwarding](#headless-git-push-without-agent-forwarding)

That is enough to run `dejima`. The starter config `install.sh` writes has
every key commented out at its default, which means `[core] forge = none` and
`[core] workflow = local-only`: the agent works in the sandbox and commits
locally, and nothing is pushed anywhere. To have it push, pick one of the two
forge sections below and set `[core] workflow` to `worktree-pr` or
`branch-push` — a pushing workflow is refused at launch unless its forge
resolves to somewhere to push to, so the forge is not optional once you
choose one of them.

### Gitea/Forgejo PR workflow

Skip this if you use `forge = github` or `forge = none` instead (below).

1. Set `[forge.gitea] ssh_host` (the SSH hostname) and `[forge.gitea] api`
   (`https://<gitea host>/api/v1`) in `~/.config/dejima/config`.
2. Generate a token — Settings → Applications, scopes `write:repository` and
   `write:issue` — and save it to `~/.config/gitea/token`, `chmod 600`.
   → [Prerequisites](#prerequisites)

### GitHub forge (opt-in alternative)

Set `[core] forge = github` instead of the above to push and open PRs
against GitHub directly through `gh`, rather than a Gitea/Forgejo instance.
This is a persistent, per-config choice — different from the per-launch
`--allow-github-push` flag (see "GitHub push" below), and it opens
`ssh.github.com:22` for push every time this forge is selected with a
workflow that pushes, not just for one launch. It opens it through the same
grant that flag uses, so the posture is the one documented there and nothing
else about GitHub's treatment changes.

1. Generate a **write-capable** PAT, separate from the read-only
   `[github] token_file` used for read access — promoting the read-only
   token here would defeat the point of scoping it read-only.
2. Save it to a file and set `[forge.github] push_token_file` to that path.

dejima warns at startup if both `[github] token_file` and
`[forge.github] push_token_file` are set and non-empty: `gh` only reads one
token variable, and the write-capable one wins for that launch.

### Pushing nowhere

If this sandbox should never push or open a PR — read-only work, exploring a
codebase, anything where you'll take the diff out by hand — set
`[core] forge = none` and `[core] workflow = local-only`. Nothing to
configure for either; the agent commits locally and stops there, and
`git-push-guard.sh` refuses every push regardless of what else is set.

### Per-project domains and dependencies

Nothing to set up in advance; do this per project, as it turns out to need
something:

```sh
dejima-project status ~/myproject     # declared vs approved vs missing
dejima-project approve ~/myproject    # approve the declared set
dejima-allow --project ~/myproject crates.io
dejima-dep add --global cargo:cargo-nextest
```

`dejima-allow` with no scope flag patches a running session; `--project` or
`--global` instead records an approval for future sessions, and domains
apply at their next launch. Dependencies need an image rebuild, so they
always land on the next one.

`--project` records two things: the approval in `~/.config/dejima` (which is
what actually grants) and a declaration in the project's own
`.dejima/allowed-domains` (which is committed, so the rest of the project gets
it too). `--global` writes only the approval — there is no project to declare
in.

→ [Global and per-project domains and dependencies](#global-and-per-project-domains-and-dependencies),
[Adding a domain to a running session](#adding-a-domain-to-a-running-session)

### Log shipping

1. Set `[logging] loki_url` to your Loki push endpoint.
2. Optionally set `[logging] conversation = on` to ship transcripts as well —
   read
   [Conversation logging (opt-in)](#conversation-logging-opt-in) first, since
   that ships what you and the model actually say.
   → [Network request logging](#network-request-logging),
   [Viewing logs in Grafana](#viewing-logs-in-grafana)

### GitHub push (opt-in)

Per launch, not a persistent setting:

```sh
dejima --allow-github-push ~/myproject
```

Pair it with a repo-scoped deploy key in `[core] ssh_key`. Read
[GitHub push: blocked by default, optional opt-in](#github-push-blocked-by-default-optional-opt-in)
before turning it on — with a forwarded personal agent this is much broader
than it looks.

### Remote access (opt-in)

Entirely off until step 1 is done. **Read
[docs/remote-access.md](docs/remote-access.md) end to end before doing any of
this.** Step 2 is the one that carries the security of the whole feature, and
getting it wrong still looks like it works.

1. **Set `[remote-access] enabled = on`** in `~/.config/dejima/config`. This
   is the switch — nothing here runs without it. Set `ntfy_url`, `base_url`,
   and `ttyd_port` in the same section if you want something other than
   7681. →
   [`[remote-access]`](docs/remote-access.md#remote-access)
2. **Choose the reverse proxy's bind address, on the dejima box itself.** One
   specific address on its LAN interface. Never the wildcard, never
   `0.0.0.0`, never a Docker bridge. →
   [The bind address is the one thing to get right](docs/remote-access.md#the-bind-address-is-the-one-thing-to-get-right),
   [Picking the address](docs/remote-access.md#picking-the-address)
3. **SSH front door.** Generate a key that exists only for this, then add one
   `restrict,pty,command="…/dejima-attach"` line to `authorized_keys` for the
   same Unix user that runs `dejima`. →
   [SSH front door](docs/remote-access.md#ssh-front-door)
4. **Web front door.** Get `ttyd` 1.7.4 or newer. If it came from a distro
   package, `systemctl disable --now ttyd.service` **and** `mask` it first —
   the package ships an enabled service that puts a login prompt on every
   interface, reachable from inside your sandboxes. Then install
   `systemd/dejima-ttyd.service` as a *user* unit, and put a reverse proxy in
   front of it adapted from `docs/nginx-dejima.conf.example` — with
   authentication on every server block, TLS, a `default_server` that
   refuses every other hostname, and
   `proxy_set_header Host $http_host`. Make sure the name you pick actually
   resolves to this box and your certificate covers it. →
   [Web front door](docs/remote-access.md#web-front-door)
5. **If you will read it on a phone**, there is nothing to turn on: the front
   door serves a touch frontend by default, with gestures for scrolling,
   selection and pane resizing, and a toolbar carrying Esc, a sticky Ctrl, the
   arrows and tmux's window switching. Set `ttyd_tmux_prefix` in
   `[remote-access]` if your tmux prefix is not `C-b`. →
   [Reading it on a phone](docs/remote-access.md#reading-it-on-a-phone). Typing from one has its
   own gotcha, which nothing here can fix. →
   [Typing on a phone](docs/remote-access.md#typing-on-a-phone)
6. **If another reverse proxy sits in front of this one**, it needs SNI, a
   single literal `Host`, the upgrade headers and its own long read timeout —
   and it changes the threat model. →
   [Behind another reverse proxy](docs/remote-access.md#behind-another-reverse-proxy)
7. **Notifications.** Install `systemd/dejima-notify-watch.service` the same
   way, then `loginctl enable-linger "$USER"` so both units survive logout. →
   [Notifications](docs/remote-access.md#notifications)
8. **Verify the containment from inside a running sandbox** before relying on
   any of it. →
   [Verifying it](docs/remote-access.md#verifying-it)

[Attaching](docs/remote-access.md#attaching) then covers what you get on the other end.

## Usage

Run `./install.sh` first — it symlinks the CLIs into `~/.local/bin` and the
hooks into `~/.claude/hooks`, and everything below assumes those are on your
`PATH`. See [Setup](#setup) for the rest of the first-run steps.

```sh
dejima                        # sandbox the current directory
dejima ~/repos/some-project
```

By default the container's entry point is bare `claude` (always running with
`--dangerously-skip-permissions`, regardless of how it's invoked — see
`docker/claude-wrapper.sh`), so a fresh clone of this repo works with no
editor setup at all.

Typical loop: point it at a project, ask Claude to implement something and
open a PR (`gitea-pr` is on `PATH`); from the host, `gitea-pr comments <PR#>`
to pull review feedback, feed it back in, repeat. Merging is yours — see
`merge-guard.sh` below. `gitea-issue` is on `PATH` too, for the work
that gets deferred rather than done: `list`, `view`, `create`, `comment`,
`close` and `reopen`, so a problem found mid-session becomes a ticket instead
of a footnote on an unrelated PR.

`gitea-actions` closes the other half of that loop. A sandbox cannot run the
tests that need a Docker daemon, so CI is where they run, and without a way
to read a run the only route from a red build back into the session is the
operator pasting the log in by hand. `gitea-actions runs`, `jobs <run>` and
`logs [run]` do that instead — with no run given, the newest one for `HEAD`,
and by default only the jobs that failed. It reads and never writes.

Because the session stops at the PR and you merge afterwards, the sandbox
context tells Claude to put `Fixes #N` in the PR body rather than to close
issues by hand once they land — the merge is the last step in that sequence
that still happens, and it happens when the agent is gone. `Refs #N` is the
deliberate opposite, for work that touches a ticket without finishing it.

Both take `--body-file FILE` (or `-` for stdin) as well as `--body`. Prefer it
for anything with an apostrophe, a backtick or a code fence in it — a body
passed on a command line has to survive shell quoting first.

Inside the sandbox there's a second reason, and it argues for a real file over
a heredoc. `deny-dangerous-bash.sh` matches patterns anywhere in the Bash
command string, and it has no way to tell an instruction from prose that
merely mentions one — so a PR or issue body that discusses restarting a host,
or quotes a destructive command it is warning about, gets the whole call
blocked. Writing the body to a file first keeps that text out of the command
string entirely. A heredoc doesn't: the body is still part of the command the
hook reads, so it solves the quoting problem but not this one.

### Using a different editor/application

```sh
dejima --cmd nvim ~/repos/some-project
```

Runs unconfigured unless you also set `[mounts] nvim_config` in the config to
a real config directory on the host (bind-mounted read-only at
`~/.config/nvim` — lazy.nvim's lockfile is the one exception, layered
read-write on top so plugin syncs don't fail on a read-only filesystem;
nothing else in the config is writable):

```
[core]
command = nvim

[mounts]
nvim_config = ~/.config/nvim
```

Set both in `~/.config/dejima/config` if you use this mode regularly, or pass
`--cmd nvim` per launch once `nvim_config` is set.

If your config references something outside that directory by absolute host
path (a helper script in a dotfiles `bin/`, say), bring it in with
`[mounts] readonly` (colon-separated, mounted read-only at the same path):

```
[mounts]
readonly = ~/dotfiles/bin
```

### Writable host directories

`[mounts] read_write` is the same thing without `:ro` — for a directory a
session is meant to write to and whose contents should outlive the container:

```
[mounts]
read_write = ~/specs
```

Both lists mount at the host path they name, which is the point: a convention
that says "specs live in `~/specs`" keeps working inside the container without
being rewritten. That is the difference from `[core] share_dir`, which is
mounted at `~/shared` regardless of where it lives on the host because its job
is to be a well-known handoff point.

An entry is **refused, not warned about**, if it overlaps anything dejima
relies on being out of a session's reach: the approval store, either audit
store, `~/.claude`, `~/.local/bin`, dejima's own checkout, or the project mount
(already read-write, so listing it again is a mistake worth surfacing). A
writable mount over any of those would let a session approve its own domains,
delete the audit findings naming it, or plant code that runs unsandboxed on the
host next time you start an agent. Overlap is checked in both directions after
resolving symlinks, so `read_write = ~` is caught too.

Sessions are told which directories these are, so "everything else is
disposable" stays true in the briefing rather than becoming a trap.

## Config parity with your host Claude Code setup

Global `CLAUDE.md`, settings, hooks, skills, and plugins all carry over
automatically, and your existing login stays effective too — no separate
first-run login, though the credential itself never enters the container
(see [security notes](docs/security.md) for the host-side proxy that makes
that work).

`~/.claude` itself is *not* shared as a whole: its contents are enumerated
in `docker-compose.yml`, config files are copied in rather than mounted,
and anything not listed is container-local — writable during the session,
gone with the container. Session transcripts, plans, and the edit-undo
record are on the list, so `claude --resume` on the host still works; a
credential, cache, or newly-added config file is not. The
[security notes](docs/security.md) explain the split and why single-file
mounts couldn't be trusted here. (`~/.claude.json` is handled differently
again — a throwaway per-session copy, not the real file.)

The project directory is mounted at the *same absolute path* inside the
container as on the host, so Claude Code's session-history keying lines up
between host and container: a session's transcript is visible on the host
afterward, and `claude --resume <session-id>` should find it there. (Whether
a bare `claude --resume` with no ID picks it as the "most recent" session
depends on `~/.claude.json`'s own bookkeeping, which — per the throwaway-copy
design above — doesn't carry over from a sandboxed session.)

The container's own user matches yours exactly — username, uid, gid, and
home directory (see `Dockerfile`) — so `$HOME`-relative paths (dotfiles,
Claude Code's plugin bookkeeping) resolve the same on both sides. Defaults to
`node`/1000/1000/`/home/node` if you build the image directly instead of via
`dejima`. Images are tagged per-user (`dejima:<username>`)
so concurrent builds on a shared machine don't clobber each other.

Your global `~/.gitconfig` also carries over (as a throwaway copy, so commits
made inside the sandbox get the right identity, but nothing written to it
during a session reaches your real file). Falls back to an empty config if
you don't have one.

Caveat: MCP servers or hooks that shell out to host-specific binaries (a
browser, a language runtime not installed here) may not work unless that
tooling is also added to the `Dockerfile`.

### Headless git push without agent forwarding

Agent forwarding (the default) ties SSH access to whichever client is
currently connected — it dies when that client disconnects, breaking
git-over-ssh for anything still running headless. For sandboxes meant to run
unattended, generate a dedicated, purpose-built keypair instead:

```sh
ssh-keygen -t ed25519 -N '' -f ~/.ssh/dejima_ed25519
```

Passphrase-less is deliberate — this is meant to be a low-privilege
credential living only inside the container, not your personal identity. Add
the public half as a Gitea deploy key scoped to just the repos that need
push access, then set it in the config:

```
[core]
ssh_key = ~/.ssh/dejima_ed25519
```

`entrypoint.sh` loads it into a container-local `ssh-agent` at startup and
deletes the plaintext copy immediately after — the sandbox user itself never
has a path to the raw key, only the agent socket (see
[security notes](docs/security.md) for the full mount rationale). Setting
`[core] ssh_key` means a live forwarded agent is no longer required at all.

## Shared scratch space

`~/shared` is a read-write bind mount of `[core] share_dir` (default
`~/.local/share/dejima/shared`, created automatically) — separate
from the project mount, for passing files (screenshots, temp scripts) in and
out of a session without touching the actual checkout. Persists across
sessions since it's a real directory, not a container volume.

Treat it as a handoff point, not as general-purpose storage. If your own
project instructions tell agents to write somewhere at a fixed host path —
design docs, scratch notes, anything meant to outlive the session but stay out
of the project checkout — mount that directory instead, with
`[mounts] read_write`. It arrives at its own absolute path, so a convention
that says "put specs in `~/specs`" keeps working inside the container without
being rewritten to point at `~/shared`.

`~/shared`, the project mount, and anything in `[mounts] read_write` are the
only writable host paths in the container. Everything else a session writes
goes away with it.

## Testing frontend changes

Playwright (Chromium) is pre-installed at image build time, browser
included — `require("playwright")` works from any script, no network access
or per-project `npm install playwright` needed.

`localhost`/loopback traffic never goes through the egress firewall, so a
project's own dev server needs no firewall changes. A real external site
needs to be on the allowlist like any other network use
(`dejima-allow <domain>` for a running session, add
`--global`/`--project <path>` to persist it) — the firewall applies to the
browser's traffic exactly like `curl`/`git`.

If a project pins its own `playwright`/`@playwright/test` version, its
`npm install` may try to download a different Chromium build from
Playwright's CDN, which isn't allowlisted by default — allow it the same way
as any other one-off domain need.

Chromium's own process sandbox isn't actually active in this image (its
setuid helper isn't setuid here) — not a concern, since the container itself
is already the boundary that matters, and a compromised session already has
full shell access as the container's own user regardless.

## Sandbox self-awareness

### Project instructions: `.dejima.md`

`.dejima.md` at a project's root is that project's agent-instruction file —
the same role `CLAUDE.md` plays for Claude Code — under a name that doesn't
name a harness. dejima loads it into the session's opening context the way the
harness would load its own, so a project's instructions apply whichever agent
is running.

The reason for a second name: Claude Code finds a `CLAUDE.md` by itself, and
nothing else does. As dejima grows the ability to run agents that aren't Claude
Code, a project that wants to say "here is how to work on me" needs one file
that reaches all of them — so dejima delivers it rather than leaving each
harness to go looking for its own.

Loaded verbatim, capped at 16 KB with any truncation noted in the text. It
carries no authority over the sandbox itself: the file sits on the read-write
workspace mount, so nothing in it widens the firewall, relaxes a guard, or
authorises a push, and the text delivered around it says so.

This repo ships one, describing which half of its own test suite a sandboxed
session can run.

### The session briefing

A `SessionStart` hook (`~/.claude/hooks/sandbox-context.sh`) injects a
reminder when `DEJIMA` is set: the session is running in a
disposable, firewalled container and should stay within the task at hand —
if something genuinely needs to break out (broader network, host changes,
GUI/hardware), stop and ask rather than trying to work around the firewall,
since the same session can be resumed unrestricted on the host via
`claude --resume`. No-op outside the container. `deny-dangerous-bash.sh`
(`PreToolUse`) also applies here, since `~/.claude/hooks` is mounted in.

`git-push-guard.sh` (`PreToolUse`/`Bash`, also `DEJIMA`-gated) blocks
any `git push` whose resolved remote isn't the Gitea host, and any push to
`main`/`master` even there. Like the other hooks, this is a fast-fail guard
against an overeager agent, not a hard security boundary — a session has full
shell access and could in principle edit `.git/config` to route around it.
GitHub push is blocked by default too (see "GitHub push" below) unless
`--allow-github-push` is given. For a real guarantee against pushes to
main/master, use branch protection on the remote itself.

`merge-guard.sh` (`PreToolUse`/`Bash`, `DEJIMA`-gated) blocks
`gitea-pr merge` inside the sandbox. It's the API-side counterpart to the rule
above: a merge puts a branch on `main` without ever performing a push, so
`git-push-guard.sh` never sees it. A hook is handed a command rather than a
conversation, so it can't tell an instructed merge from an unprompted one —
which is why it's scoped to the sandbox rather than applied everywhere. On the
host it does nothing, and you can still ask an agent to merge. The same
fast-fail caveat applies with more force than usual here: the session has the
Gitea token in its environment and could call the merge endpoint with `curl`
directly. Branch protection on the remote is the real guarantee.

`sandbox-context.sh` also tells the agent the actual workflow to follow: do
new work in a `git worktree` under the mounted project (e.g.
`.worktrees/<branch>`, never `../<branch>` or elsewhere under `$HOME` — only
the bind-mounted path is backed by real host storage, so a worktree created
outside it silently vanishes with the container), then push the feature
branch and run `gitea-pr create`.

## Network egress firewall

On start, the container runs an allowlist-only `iptables`/`ipset` firewall
(`init-firewall.sh`), matching the reference dev container. Allowed by
default:

- DNS resolution via a local proxy (see "DNS is allowlisted too")
- the Docker host itself (not its whole subnet)
- GitHub's published IP ranges, port 443 only (see "GitHub push" below)
- `registry.npmjs.org` and `platform.claude.com` (the harness and its
  updates), `release-assets.githubusercontent.com` (GitHub release assets, a
  separate CDN from github.com's own IPs, and where a good deal of tooling
  fetches its binaries); `api.anthropic.com` when the credential proxy is off
  (kill switch or API-key auth)

  That is the whole built-in list, and it is meant to stay that way: it covers
  what the sandbox itself cannot run without, not what a project might want.
  Language package hosts are approved rather than assumed — `pypi.org`,
  `proxy.golang.org`, `crates.io` and the rest are one `dejima-allow --global`
  or one reviewed `.dejima/allowed-domains` line away. The reason to keep the
  built-in list short is that everything on it is reachable from every sandbox
  on the host whether or not a project has any use for it, and a name granted
  by being built in is a name nobody ever reviewed
- whatever the selected forge needs reachable (`[forge.gitea] ssh_host`/`api`
  by default) — not port-restricted, so git-over-ssh to the forge works
  without a blanket "port 22 to anywhere" rule, and exempted from DNS-rebind
  protection because a self-hosted forge host legitimately resolves to an
  internal address. `[core] forge = github` is deliberately *not* added here:
  its three hostnames are public names already covered by the GitHub entry
  above, so they stay on that entry — 443 by default, plus port 22 when the
  selected workflow pushes, exactly as `--allow-github-push` opens it per
  launch — rather than picking up all-port egress and losing rebind
  protection on the way

Everything else is rejected. Run `dejima-allow --global <domain>`
(or `--project <path>` for one project) to allow more permanently (e.g.
`crates.io` for a Rust project), or `dejima --no-firewall` to disable the
firewall entirely for one launch (debugging only).

IPv6 is blocked outright (`ip6tables` DROP on INPUT/OUTPUT/FORWARD, `dnsmasq`
strips AAAA answers) — there's no IPv6 equivalent of the allowlist above, so
leaving it open would bypass the whole firewall on any host with IPv6
egress.

If your Gitea host only resolves via a LAN-local DNS server, make sure the
Docker host itself can resolve it — containers inherit the host's resolver.

### DNS is allowlisted too

Resolution itself is restricted, not just the IP connections made
afterward: `dns-proxy.sh` runs a local `dnsmasq` with no fallback resolver,
and `/etc/resolv.conf` is repointed at it. Only names on the same allowlist
above (plus `github.com`/`githubusercontent.com`/`githubassets.com`, needed
since GitHub itself is allowlisted by IP range — see `fixed-domains.sh`) get
forwarded to Docker's real resolver; anything else gets no upstream
configured at all and is refused outright. Without this, a compromised
session could exfiltrate data by encoding it into query names to an
attacker-controlled domain, even with no direct connection ever possible.

### Adding a domain to a running session

Approved domains only take effect at container start. For a domain a
*running* session needs right now, run from the host (not inside the
sandbox — it has no privilege to do this itself):

```sh
dejima-allow crates.io                    # this running session only
dejima-allow --container <id> crates.io   # a specific session, if more than one is running
```

It first adds the domain to the running dnsmasq's allowlist (appends a
`server=` line to its servers-file and sends `SIGHUP` to reload just that
file - no restart), then resolves it through the now-unblocked container
resolver and adds the IP(s) to the running firewall's `ipset`, all via
`docker exec -u root`. It finishes by checking the domain is actually
reachable from inside that same container and prints a definitive verdict
— exit code 2 if it isn't.

`--global` and `--project` are the opposite of this: they record an approval
for *future* sessions and deliberately do not touch a running container, even
together - see
[Global and per-project domains and dependencies](#global-and-per-project-domains-and-dependencies)
below, since the domain being approved may legitimately not answer on 443 (an
internal service, an SSH-only host) and the natural moment to add an approval
is precisely when nothing is running to probe in the first place. Pass
`--container <id>` alongside a scope flag to do both in one call:
`dejima-allow --global --container <id> crates.io` records the approval and
patches that session immediately, in that order, so the approval is never
lost to a live-session failure. If more than one dejima container is
running, the bare form above refuses and asks you to disambiguate with
`--container <name>` - `docker ps` finds it, or use the
container's own ID, which `sandbox-context.sh` already hands the agent in
its startup context (and which is always available inside the sandbox as
`cat /etc/hostname`), so there's no need for it to guess one and risk
"successfully" updating someone else's session instead.

A domain allowed this way stays allowed for the rest of the session even
if its CDN later rotates edge IPs: `dns-proxy.sh` tops up the firewall's
`ipset` from every DNS answer it serves, not just the one resolved at
allow-time, since only allowlisted names get an upstream to answer from in
the first place. GitHub's own domains sit outside this - their existing
port-443-only `ipset` entries still win by dnsmasq's longest-match rule -
so that restriction is unaffected.

One gap remains: allowing an *internal* hostname (one that resolves to an
RFC1918 address) mid-session doesn't work. dnsmasq's `stop-dns-rebind`
rejects private answers for any domain not exempted at startup, and that
exemption list can only be extended by restarting dnsmasq. Internal hosts
named before the container starts (`[forge.gitea] ssh_host`, `api`,
`[logging] loki_url`, and any globally or per-project approved domain) are
already exempted and unaffected by this.

The sandbox-context.sh `SessionStart` hook tells the agent to ask for this
by name when a task is blocked on a single missing domain, rather than
stopping the whole session over it.

## Global and per-project domains and dependencies

Allowed domains and dependencies each stack through their own layers, least
specific first:

| Config | Layers, least specific first |
| --- | --- |
| Allowed domains | built-in → global → project → container (one session) |
| Dependencies | base image → global → project |

Dependencies have no container-only scope: installing one always needs an
image rebuild, so there's no `dejima-allow`-style live-session patch
for them.

A project can declare what it needs in two committed files:

```
.dejima/allowed-domains    # one domain per line
.dejima/dependencies       # <apt|npm|pip|cargo>:<name> per line, or a
                           # tarball:<name>@<sha256>:<url> release archive
```

### Tarball dependencies

For a toolchain no package ecosystem ships in a version you can use — a
current Go, say, where Debian's is several releases behind — a dependency can
name a release archive instead:

```sh
dejima-dep add --global tarball:go@<sha256>:https://go.dev/dl/go1.25.0.linux-amd64.tar.gz
```

It unpacks with `--strip-components=1` into `/opt/dejima/<name>`, and
`/opt/dejima/<name>/bin` goes on `PATH`. That one convention covers the usual
shapes without the spec needing layout options: a Go archive has everything
under `go/`, an nvim release under `nvim-linux-<arch>/`, and stripping one
level puts `bin/` in the same place for both. Compression is detected from the
archive, so `.tar.gz`, `.tar.xz` and `.tar.zst` all work.

**The digest is mandatory**, and it is checked before anything is unpacked.
Without one you would be approving a *name* whose contents the far end can
change afterwards, which isn't a decision anyone can make once. With one, what
you approved is a specific archive and nothing else can take its place. Two
consequences worth knowing:

- **A tarball dependency names one architecture**, because a digest does.
  Unlike a package name, it can't resolve per-host, so a mixed-architecture
  fleet needs a spec per project rather than one global one.
- **Upgrading is an approval, not a version bump.** A new release is a new
  digest, so it goes through `dejima-dep add` and `dejima-project approve`
  again — which is the point, not friction to route around.

The URL's character set is deliberately narrower than URLs allow: the spec is
interpolated into a `RUN` line that runs as root at build time, so anything
shell-active is refused outright rather than quoted around, and only `https`
is accepted.

**Declaring grants nothing.** The project directory is bind-mounted
read-write, so a compromised session could write these files - they are read
only to compare against reality and suggest a command. Approvals live
outside the container, under `~/.config/dejima/` by default
(`$DEJIMA_CONFIG_DIR` relocates the whole tree) - global at its
root, per project under `projects/<slug>/` - and are written only by tools
you run on the host:

```sh
dejima-project status ~/myproject     # declared vs approved vs missing
dejima-project approve ~/myproject    # review and approve the declared set
dejima-allow --project ~/myproject crates.io
dejima-allow --global crates.io       # applies to every project
dejima-dep add --project ~/myproject cargo:cargo-nextest
dejima-dep add --global cargo:cargo-nextest
```

Two of those tools also write the declaration, so an approval you make by
hand does not stay invisible to everyone else on the project:
`dejima-allow --project` appends to `.dejima/allowed-domains`, and
`dejima-dep add --project` appends to `.dejima/dependencies`. Both write the
approval first — that is the part that grants — and report separately on the
declaration, so a project you can't write to still gets you the approval.
`--global` writes no declaration at all: there is no project to declare in.

The declaration those two write still grants nothing; it is the same
untrusted file the section above describes, and writing to it does not
promote it. That it is session-writable is exactly why both tools refuse to
write a `.dejima` directory or a `.dejima/<kind>` file that is a **symlink**:
a compromised session can plant one and then ask you to run the command that
follows it, which would aim a host-side append at your approval store or at
any other file you can write. The refusal is the `open` itself rather than a
test before it — `O_NOFOLLOW` on both, with the file opened relative to the
already-opened directory — so a session that is still running while you type
the command cannot swap `.dejima` or the declaration file out from under the
write. (Those two leaves are what the session controls. A symlink further up
a `--project` path you supply yourself is still resolved through.) Expect the
session to be live: the agent briefing tells the agent to ask you to run
`dejima-allow --project` from a terminal outside the sandbox. The same write
reads the file back to skip an already-declared entry, and that read is
capped — a session can make its own `.dejima/<kind>` arbitrarily large for
free, and an oversized one is refused rather than loaded into your memory.

Neither writer has an inverse for the declaration. `dejima-dep remove
--project` withdraws the approval and deliberately leaves the declaration
alone (it says so, since `dejima-project approve` will otherwise offer the
entry again); `dejima-allow --project` has no `remove` at all. Taking
something back from the project itself means editing `.dejima/` and
committing that.

`dejima-project status`/`approve` classify a declared entry against
the union of global and project approvals, so something already approved
globally shows as approved, not pending. Unlike `dejima-allow`,
`dejima-dep`'s `--global` and `--project` are mutually exclusive -
an entry belongs to exactly one scope. `dejima-dep` has no `--container`
scope either, and refuses the flag rather than ignoring it: a dependency
needs an image rebuild, so there is nothing to patch in a live session.

Approved domains join the allowlist at the next launch. `dejima-allow` can
also patch a running session immediately, but only when it is run bare or
with `--container` - approving here (`--project`/`--global`, with no
`--container`) never touches one; see
[Adding a domain to a running session](#adding-a-domain-to-a-running-session).
Approved dependencies are baked into a derived image built `FROM` the shared
base - first `dejima:<username>-global`, if the global store has any
dependency approved, then `dejima:<username>-<slug>` on top of that,
if the project store does - so they need an image rebuild: they take effect
on the **next** launch.

Because of that rebuild, the usual moment to approve is *after* leaving the
sandbox — so persistence (`--global` or `--project`) never requires a running
container.

`dejima-project approve` never attempts to patch a running session: it only
ever calls `dejima-allow` without `--container`, so recording the approval
is the only thing it does. If an individual approval can't be recorded — an
unwritable store, a slug collision, a corrupt approval list — it reports
that entry as not approved and keeps going, rather than stopping at the
first failure; that holds for dependencies and domains alike, so one bad
entry can't cost you the rest of the set. It then exits non-zero if anything
failed, so `dejima-project approve ~/myproject && dejima` won't launch a
session missing the approvals you just confirmed.

A session whose project declares something it doesn't have is told so in its
startup context, with the exact command to hand you. Project approvals are
inherited by subdirectories, so a git worktree under the project gets its
parent's; global approvals apply everywhere regardless.

## Network request logging

If `[logging] loki_url` is set (see Prerequisites), every DNS query and every new
outbound connection attempt - allowed or rejected - is shipped to that Loki
endpoint. Two sources, both tailed and pushed by `log-shipper.sh`:

- `dns-proxy.sh`'s dnsmasq logs every query and whether it was forwarded
  (allowed) or refused (not on the allowlist) - labeled `job=dejima-dns`.
- `init-firewall.sh` tags its terminal ACCEPT/REJECT rules with `NFLOG`
  (group 1 for allowed, group 2 for rejected), which `ulogd2`
  (`ulogd.conf`) turns into JSON lines with source/dest IP, port, and an
  `action` field - labeled `job=dejima-net`. Only new connection
  attempts are logged, not every packet: the firewall's existing
  ESTABLISHED,RELATED rule short-circuits the rest of a connection before it
  ever reaches the tagged rules.

This is visibility on top of the firewall/DNS-proxy enforcement above, not a
substitute for it - nothing about logging changes what's actually allowed to
resolve or connect.

### Conversation logging (opt-in)

Set `[logging] conversation = on` (with `loki_url` configured) to also ship
session content to Loki as the `dejima-conversation` job: your
prompts, the agent's text responses, and tool invocations (tool name +
input - never tool outputs). Lines are JSON with the session ID inside
(`{session, role, text}` / `{session, role: "tool", tool, input}`).

Off by default - conversation content is a different sensitivity class
than DNS names and firewall verdicts, so it never leaves the container
unless you opt in. Transcripts of every session under the mounted
workspace (including worktrees and subagent sessions) are shipped while
the sandbox runs.

### Viewing logs in Grafana

Nothing sandbox-specific needed on the Grafana side beyond a Loki data
source pointed at wherever `[logging] loki_url` resolves to (Connections → Data
sources → Loki, if one isn't already configured against that instance) -
`log-shipper.sh` pushes directly to Loki's HTTP API, there's no Prometheus
scrape target or exporter involved.

In Grafana's Explore view (or a dashboard panel with a Loki query), both
streams are selectable by their `job` label:

```logql
{job="dejima-dns"}                          # every DNS query + verdict
{job="dejima-net"}                          # every connection attempt, as JSON
```

Useful filters on top of those:

```logql
# DNS lookups that got refused (not on the allowlist)
{job="dejima-dns"} |= "REFUSED"

# Rejected connections only (parses ulogd2's JSON, filters on its action field)
{job="dejima-net"} | json | action="blocked"

# Both streams together, e.g. to watch a live session across sources
{source="dejima"}
```

`{job="dejima-net"}` lines are one full ulogd2 JSON object per
connection attempt (`| json` in a query unpacks fields like `dest_ip`,
`dest_port`, `action`) - Loki's Explore view shows these expandable/
pretty-printed by default, no extra parsing setup needed.

## GitHub push: blocked by default, optional opt-in

This section is about `--allow-github-push`, a per-launch flag that adds
GitHub as a push destination on top of whichever forge is selected, without
changing that selection. It adds a destination; it does not stand in for a
forge, so the launch-time rules for the selected forge/workflow pair still
apply exactly as they would without it. If you
want GitHub push and PRs as a standing choice instead, set
`[core] forge = github` — see "GitHub forge (opt-in alternative)" above; it
also opens `ssh.github.com:22`, but persistently rather than per launch, and
uses its own `[forge.github] push_token_file` rather than a loaded SSH key.

The sandbox can always read from GitHub (clone, fetch, `gh` API calls). By
**default** it can never push there — enforced at the network layer, not
just by `git-push-guard.sh`: GitHub's IP ranges are only allowlisted on port
443. Port 22 is unreachable, so SSH-based push has no transport at all,
regardless of what any hook does or doesn't catch.

**Opt-in, not hardcoded** — pass `--allow-github-push` to open port 22 to
GitHub and let `git-push-guard.sh` accept `github.com`/`ssh.github.com` as a
push destination (the no-direct-to-main rule still applies):

```sh
dejima --allow-github-push ~/repos/some-project
```

**Read this before turning it on.** Whether a push actually succeeds depends
entirely on what SSH key is loaded into the agent. A forwarded personal
agent with your normal GitHub key would let a compromised session push to
**any** repo that key can write to, not just the one you intended — agent
forwarding doesn't distinguish push from pull. Use a dedicated,
**repo-scoped GitHub deploy key** via `[core] ssh_key` instead whenever
`--allow-github-push` is set — that's what actually limits the blast radius.
`--allow-github-push` only changes the firewall/hook's *host* check; it adds
no credential-loading path of its own. The flag itself has no config-file
equivalent — an exported or saved value must not silently grant a push path,
so *this* opt-in stays a per-launch decision only. Selecting `[core] forge =
github` (see above) is a config-file path that opens the same port, but not
silently: `hosts_allowlisted_by_core` is what asks for it, explicitly, in a
manifest, and only when the selected workflow actually pushes. What it opens
is the same GitHub ranges the read-only path already allows on port 443, now
also on port 22, logged like every other allowed connection and verified by
the firewall's own startup self-check.

`[github] token_file` must point at a **read-only** fine-grained PAT
regardless of this setting. `gh auth setup-git` (run at container start if
that file exists) points git's github.com HTTPS credential helper at `gh`,
which only ever holds whatever token that file provides — a write-scoped
token there would make HTTPS push possible independent of
`--allow-github-push`, so don't use one.

## Remote access

**Opt-in, and off entirely unless `[remote-access] enabled = on` is set in
`~/.config/dejima/config`.** Reach a running sandbox from another machine or
a phone - over SSH or a browser - and get a push when a session wants you.
Two front doors and a notification path, none of which exist until you
configure them.

It is documented separately because getting the bind address wrong is the one
mistake here that exposes a `--dangerously-skip-permissions` shell to your
network, and that deserves more room than a section.

**→ [docs/remote-access.md](docs/remote-access.md)** - `[remote-access]`, picking a
bind address and verifying it, the SSH and web front doors, reading and typing
on a phone, running behind another reverse proxy, notifications, and attaching.

## CI: push access is code execution elsewhere

If the project has CI, **granting a session push access grants it code
execution on whatever host that CI runs on** - and nothing in the chain needs
you. The push guard permits a feature branch, the briefing tells the agent to
open a pull request without asking, `on: pull_request` fires, and the runner
executes that commit. Merging is a decision you make *after* the code has
already run, and it does not take a modified workflow file to get there: a
workflow that runs a test suite runs every file in it.

The sandbox bounds what a session can reach directly. It does not bound what
it can arrange to have run elsewhere. Read this one before you point a
sandbox at a project whose CI you administer - and if you would rather not
take it on, `[core] forge = none` with `[core] workflow = local-only` declines
the push grant and the code execution with it.

**→ [docs/ci.md](docs/ci.md)** - the *why*: no approval gate is offered and
what that leaves, hardening a runner, and making CI's egress allowlist a
version-controlled artifact read from `main`.

**→ [dejima-ci-hardener](https://gitbox.example.com/branderson/dejima-ci-hardener)** - the *how*: a self-contained tool that
hardens a CI runner, installed on the CI box and nowhere near a dejima host.
Nothing in this repository needs to be copied onto a runner.

## Security notes

What this sandbox does and does not protect you from - the containment
boundary, what a compromised session can still reach, the deliberate
trade-offs behind `--dangerously-skip-permissions`, and why the exit-time
audit's findings are a time window, not a verdict on who caused them.

**→ [docs/security.md](docs/security.md)**

## Tests

`test/` has a [bats](https://github.com/bats-core/bats-core) suite covering
the security invariants above - not a substitute for reading this document,
but a way to actually catch a future change silently breaking one of them
instead of finding out the hard way:

```sh
bats test/               # everything
bats test/audit.bats     # one area - the suites are independent, see .dejima.md
SKIP_BUILD=1 bats test/runtime.bats   # the one suite needing Docker; reuse the current image
```

`.gitea/workflows/tests.yml` runs all of it on every pull request and on every
push to one, `runtime.bats` included. That job needs two things from the
runner that an ordinary one doesn't — the host's Docker socket and the host
network namespace — and it checks for both up front rather than failing
obscurely partway through; the file says why each is needed.

`static.bats` greps the repo's own files - no sudo in the `Dockerfile`, every
`ipset add` is duplicate-safe, no `docker.sock`/host-credential mounts, the
`~/.claude` mount inventory is exactly what it should be, `dejima-allow`
rejects a malicious domain argument. `runtime.bats` builds the image, boots
a real container running the actual `entrypoint.sh` (a `SANDBOX_TEST_MODE`
env var makes it stop just short of execing `$SANDBOX_CMD`, so the suite can attach
to a fully-initialized container instead of reimplementing its own copy of
the setup sequence), and asserts against it: IPv6 blocked, DNS/IP allowlist
enforcement in both directions, GitHub read-only, no working `sudo`/
`iptables`/`init-firewall.sh` as `node`, capabilities actually stripped
(not just absent from a `docker exec` that doesn't have them to begin
with), `ulogd2` unprivileged, and the dynamic-ipset CDN-rotation fix.

The other three need no Docker either. `project.bats` covers the
declaration/approval split - what `.dejima/` may ask for, what only the host
can grant, and that the approval store is never mounted. `remote.bats`
covers everything in [docs/remote-access.md](docs/remote-access.md):
the `[remote-access]` config section, the session registry, and the properties the
feature's security rests on - that the
notification path carries no sandbox-controlled byte, and that no marker
name outside `waiting`/`done` is ever acted on. `audit.bats` covers
`bin/dejima-audit`'s own diffing.

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

## Files

| File | Purpose |
| --- | --- |
| `docker/Dockerfile` | Base image, dev tools, nvim, Claude Code + wrapper, `gitea-pr`/`gitea-issue` |
| `docker/fixed-domains.sh` | Shared domain list sourced by both `init-firewall.sh` and `dns-proxy.sh` |
| `docker/dns-proxy.sh` | Starts the DNS-allowlisting `dnsmasq`, repoints `resolv.conf` at it |
| `docker/init-firewall.sh` | IPv4/IPv6 egress allowlist firewall, run at container start |
| `docker/ulogd.conf` | `ulogd2` config: turns `init-firewall.sh`'s NFLOG-tagged packets into JSON |
| `docker/log-shipper.sh` | Tails the dnsmasq/ulogd2 logs and ships them to `$LOKI_URL`; also ships session transcripts when `SANDBOX_LOG_CONVERSATION=1` |
| `docker/entrypoint.sh` | Runs as root: DNS proxy, firewall, logging, drops to the sandbox user via `gosu`, execs `$SANDBOX_CMD` |
| `docker/claude-wrapper.sh` | Shadows `claude` on `PATH` to always add `--dangerously-skip-permissions` |
| `docker/docker-compose.yml` | Wires up mounts/env; invoked via `bin/dejima`, not directly |
| `hooks/sandbox-context.sh` | `SessionStart` hook: injects sandbox context/workflow reminders, and any `.dejima.md` the project ships |
| `.dejima.md` | Project-level agent instructions, harness-agnostic — `CLAUDE.md`'s role under a neutral name. dejima loads a project's into the session context; this one is dejima's own |
| `hooks/git-push-guard.sh` | `PreToolUse` hook: blocks pushes outside the allowed host(s)/branches |
| `hooks/deny-dangerous-bash.sh` | `PreToolUse` hook: blocks obviously destructive Bash commands |
| `hooks/merge-guard.sh` | `PreToolUse` hook: blocks the configured forge's merge command (`DEJIMA_MERGE_BLOCK`) in the sandbox — merging is a human decision |
| `hooks/dejima-notify.sh` | `Notification`/`Stop` hook: drops an empty `waiting`/`done` marker for a remote-enabled session - see [docs/remote-access.md](docs/remote-access.md) |
| `bin/dejima-attach` | Lists live sessions and attaches to one; the shared core behind both remote front doors |
| `bin/dejima-audit` | Advisory exit-time diff of host-persistence surfaces (git config, `.claude/`, etc.). `dejima-audit show` / `dejima-audit ack` default to the enclosing repo |
| `bin/dejima-dep` | Review and approve project dependencies declared in `.dejima/dependencies` |
| `bin/dejima-provider-lib.sh` | Parses forge/workflow/harness manifests and composes the session briefing; not on PATH — see [docs/providers.md](docs/providers.md) |
| `forges/`, `workflows/`, `harnesses/` | Provider directories for the three axes selected by `[core] forge`/`workflow`/`harness` — data, never sourced or executed; see [docs/providers.md](docs/providers.md) |
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

`bin/dejima` is the entry point — it resolves the project path,
checks for a live `ssh-agent`, reads `GITEA_TOKEN`/`GH_TOKEN` from the token
files named in the config, discovers which host directories need mounting for symlinks under
`~/.claude` (`hooks`, `skills`, `commands`, `agents`, `output-styles`, and
top-level entries like `statusline.sh`) to resolve, and runs
`docker compose run`. `bin/dejima-allow`
adds a domain to a running session's firewall from the host - see "Adding a
domain to a running session" above. `install.sh` installs the hooks into
`~/.claude/hooks` and registers them in `~/.claude/settings.json`.

## License

This project is licensed under the GNU General Public License v3.0 or later
(GPL-3.0-or-later) — see [LICENSE](LICENSE) for the full text.

Copyright (C) 2026 Brad Anderson
