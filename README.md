# dejima

**Unsupervised agentic development you can take responsibility for.**

An agent with permission prompts turned off gets a lot done, and will
occasionally do something you would not have allowed. dejima is for making
the first worth having and the second survivable, without handing over your
machine, your network, your credentials, or the last word on what ships.

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
- **CI hardening, because push access is code execution.** A session opens a
  pull request, the workflow fires, and your runner executes that commit
  before you've read a line of it. The container bounds what a session reaches
  directly, not what it can arrange to have run elsewhere. So this one is
  work on the runner: [docs/ci.md](docs/ci.md) for what it takes, and
  [dejima-ci-hardener](https://gitbox.branderson.io/branderson/dejima-ci-hardener)
  for a tool that does it.
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

## Using this responsibly

dejima bounds what a session can reach. It has nothing to say about whether
what that session wrote should exist. That part is yours.

**Check whether they want it first.** A growing number of projects state that
they do not accept AI-assisted contributions. Fork-and-review is the right
workflow when a project is open to the work; it is not a way around a project
that has said no. Read CONTRIBUTING before you start, not after.

**Don't point it at repositories you don't own.** With an auto-push workflow a
session opens branches and pull requests on its own. Maintainers are already
drowning in low-effort AI pull requests. Fork the project, point dejima at
your fork, review and merge there, and open the upstream PR yourself, once
you would have been happy to have written it by hand.

**Don't point it at proprietary code.** dejima works to keep your code out of
an attacker's hands, and will sometimes fail. Point it only at code you could
survive losing.

**Look at what else is in the directory.** The project is bind-mounted
read-write, so a stray `.env`, a database dump or a key someone left in the
tree is in there with the agent, reachable by anything the session runs.
Whether your *code* is sensitive is the easy half of the question.

**An allowlist entry is a grant, not a convenience.** Adding a domain is one
command. Adding your production API, a deploy webhook or a payment provider
gives an unattended agent the ability to act on the world. Unlike code, that
never passes through a diff on its way out. Allowlist things that can be
wrong without being expensive.

**Safe and responsible are not the same thing.** What you merge to `main`
becomes the baseline for everything after it: for your users, and for
dejima's own CI hardening, which reads `main` as trusted. Agents write
insecure and broken code. Prompt injection is not solved, and no firewall
short of an air gap prevents it. Supply-chain malware arrives through
allowlisted sources. Keeping that out of `main` is your job, not the
container's.

**Give it its own identity, then own what you merge.** A session should
authenticate to your forge as itself, not as you. [docs/security.md](docs/security.md)
covers how, and dejima's own development uses a separate account. With that
in place its commits and pull requests are visibly the agent's work. What
makes them yours is merging them, and the people reading your `main` will
hold you to that no matter whose name is on the commit.

**Understand what you ship.** dejima makes development fast enough that not
reading the diff gets tempting. A good model is not a substitute for
engineering judgement or human review, and nothing here changes that.

**This is not a blastproof box.** It's an improvement over running an agent
directly on your machine. A determined attacker, or one with a container
escape, defeats all of it. Use it at your own risk.

**dejima's security says nothing about your software's.** Security isn't
retrofittable: it's a property of how something was built, at every step. If
what you build inside dejima turns out to be insecure, that isn't something a
sandbox could have prevented.

→ **[docs/responsible-use.md](docs/responsible-use.md)** for the reasoning
behind each of these, and the fork-and-review workflow in full.

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
    agent forwarding" in [docs/configuration.md](docs/configuration.md).

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
   [Headless git push without agent forwarding](docs/configuration.md#headless-git-push-without-agent-forwarding)

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

→ [Global and per-project domains and dependencies](docs/configuration.md#global-and-per-project-domains-and-dependencies),
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

Typical loop: point it at a project, ask for a change, and let the session
work. It commits to a feature branch, pushes it, and opens a pull request —
then it stops. You review and merge that PR yourself, wherever you normally
read them. Merging is the one step the sandbox is not allowed to take, and
`merge-guard.sh` blocks it from the inside.

That boundary is the shape of the loop rather than a limit on it: every
session ends at something you read before it lands, and nothing reaches your
default branch without you.

How far the session goes is the `[core] workflow` setting — `worktree-pr`
pushes and opens the PR described above, `branch-push` stops at the push, and
`local-only` commits and pushes nowhere. See
[Provider axes](#provider-axes-forge-workflow-harness).

### Configuring the session

Running a different editor or application than the default (`--cmd`,
`[core] command`, `[mounts] nvim_config`), and mounting extra writable host
directories a session should have access to (`[mounts] read_write`), are
both config-file changes rather than anything you set up per launch.

**→ [docs/configuration.md](docs/configuration.md)** - both, including which
host paths a writable mount is refused over and why.

## Config parity with your host Claude Code setup

Global `CLAUDE.md`, settings, hooks, skills, plugins and git identity all
carry over, and your existing login stays effective too, with the credential
itself never entering the container. `~/.claude` is not shared as a whole -
only an enumerated subset carries over, so a session transcript is readable
from the host afterward but a credential or cache isn't. The container's own
user matches yours exactly, so `$HOME`-relative paths resolve the same on
both sides.

**→ [docs/configuration.md](docs/configuration.md)** - exactly what carries
over and what doesn't, why single-file mounts couldn't be trusted here, and
generating a dedicated deploy key for headless git push without agent
forwarding.

## Shared scratch space

`~/shared` is a read-write bind mount of `[core] share_dir`, separate from
the project mount, for passing files in and out of a session without
touching the actual checkout. It persists across sessions since it's a real
directory, not a container volume - but treat it as a handoff point, not
general-purpose storage.

**→ [docs/configuration.md](docs/configuration.md)** - when to use
`[mounts] read_write` instead, for anything meant to outlive the session at
a fixed host path.

## Testing frontend changes

Playwright (Chromium) is pre-installed at image build time, no network
access or per-project `npm install playwright` needed. `localhost`/loopback
traffic never goes through the egress firewall, so a project's own dev
server needs no firewall changes; a real external site still needs to be on
the allowlist like any other network use.

**→ [docs/configuration.md](docs/configuration.md)** - Playwright's own CDN
download, and why Chromium's process sandbox isn't active in this image.

## Sandbox self-awareness

`.dejima.md` at a project's root is that project's agent-instruction file -
the harness-agnostic equivalent of `CLAUDE.md` - loaded into the session's
context with no authority over the sandbox itself. A `SessionStart` hook
also briefs the session on where it's running and the workflow to follow: a
disposable, firewalled container, work in a git worktree, then push and open
a pull request.

**→ [docs/configuration.md](docs/configuration.md)** - `.dejima.md` in full,
and everything the session briefing covers.

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
[Global and per-project domains and dependencies](docs/configuration.md#global-and-per-project-domains-and-dependencies)
in docs/configuration.md, since the domain being approved may legitimately
not answer on 443 (an
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

A project declares the domains and dependencies it needs in two committed
files, `.dejima/allowed-domains` and `.dejima/dependencies`, stacked through
a global layer and, for domains, a container-only layer for one running
session.

**Declaring grants nothing.** The project directory is bind-mounted
read-write, so a compromised session could write these files itself; they
are read only to compare against reality and suggest a command. Approval is
a separate act, made on the host, by hand:

```sh
dejima-project approve ~/myproject    # review and approve the declared set
dejima-allow --global crates.io       # applies to every project
dejima-dep add --global cargo:cargo-nextest
```

The approval store lives under `~/.config/dejima/` by default and is never
mounted where a session could reach it, so nothing written to `.dejima/`
from inside the sandbox can approve itself. `dejima-project approve`
never attempts to patch a running session - it only records approvals, which
take effect at the next launch.

A session whose project declares something it doesn't have is told so in its
startup context, with the exact command to hand you.

**→ [docs/configuration.md](docs/configuration.md)** - the full layering,
tarball dependencies, the symlink refusal that protects the approval store,
and the complete `dejima-allow`/`dejima-dep`/`dejima-project` reference.

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
it can arrange to have run elsewhere.

**This holds for projects with no CI, too** - a branch can add the first
workflow, so what matters is which runners the repository can *reach*, not
what it runs today. That is a property of the forge rather than the project,
and it is worth one question per project before you start. On hosted runners
the answer is reassuring; with self-hosted runners in reach it is the thing to
look at. And if you would rather not take it on at all,
`[core] forge = none` with `[core] workflow = local-only` declines the push
grant and the code execution with it.

**→ [docs/ci.md](docs/ci.md)** - the *why*: no approval gate is offered and
what that leaves, hardening a runner, and making CI's egress allowlist a
version-controlled artifact read from `main`.

**→ [dejima-ci-hardener](https://gitbox.branderson.io/branderson/dejima-ci-hardener)** - the *how*: a self-contained tool that
hardens a CI runner, installed on the CI box and nowhere near a dejima host.
Nothing in this repository needs to be copied onto a runner.

## Security notes

What this sandbox does and does not protect you from - the containment
boundary, what a compromised session can still reach, the deliberate
trade-offs behind `--dangerously-skip-permissions`, and why the exit-time
audit's findings are a time window, not a verdict on who caused them.

**→ [docs/security.md](docs/security.md)**

## Tests

Every behaviour this README asserts is enforced by a test that fails when it
stops being true: that the firewall blocks what it says it blocks, that
credentials never enter the container, that a push to anywhere but the
allowed remote is refused. Hundreds of tests across suites covering
static analysis, host-side behaviour, and containers started for real.

They are the reason claims here are stated flatly rather than hedged.

→ **[docs/development.md](docs/development.md)**: the suites, what each
covers, and how to run them.

## License

This project is licensed under the GNU General Public License v3.0 or later
(GPL-3.0-or-later) — see [LICENSE](LICENSE) for the full text.

Copyright (C) 2026 Brad Anderson
