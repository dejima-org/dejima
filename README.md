# dejima

**Unsupervised agentic development you can take responsibility for.**

An agent with permission prompts turned off gets a lot done, and will
occasionally do something you would not have allowed. dejima is for making
the first worth having and the second survivable, without handing over your
machine, your network, your credentials, or the last word on what ships.

Runs a coding agent (Claude Code by default, or whatever command you point
it at) inside a firewalled Docker container with
`--dangerously-skip-permissions` (no permission prompts, all tool use
auto-accepted), against a project bind-mounted from the host. The agent gets
to work without stopping to ask; the container is what makes that a
reasonable trade rather than a reckless one.

Around that core is most of what running an agent unattended actually takes:

- **An egress allowlist.** DNS and IP, IPv4 and IPv6. Anything not on the
  list does not connect, and the agent is told so rather than left to guess.
- **Credentials that stay on the host.** Your Anthropic OAuth credential
  never enters the container: a host-side proxy holds it and the container
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
- **Logging.** Every DNS lookup and rejected connection is shipped to Loki,
  along with the session transcript if you opt in.
- **Remote access, opt-in and off by default.** Attach to a live session
  from a terminal or a browser, with a push notification when it wants you.
- **Guard rails inside the session.** Hooks refuse obviously destructive
  commands, pushes to anywhere but the allowed remote, and merging a PR from
  inside the sandbox. These are
  fast-fail guards against an overeager agent, not a boundary against a
  hostile one: the container is the boundary.
- **Config parity with your host.** `CLAUDE.md`, settings, hooks, plugins
  and git identity carry over; uid, home directory and project path match on
  both sides, so a session's transcript is readable from the host afterward.
- **An exit-time audit** of the host surfaces a session could have written
  to, so a change to your git config or `~/.claude` gets surfaced instead of
  just happening.

Originally inspired by
[Anthropic's reference dev container](https://github.com/anthropics/claude-code/tree/main/.devcontainer),
reworked to run via `docker compose` directly and grown well past it since.

This repo only holds the tooling; it's not where any project lives. Point
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
authenticate to your forge as itself, not as you.
[docs/security.md](docs/security.md#to-your-forge-the-sandbox-is-you)
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
- `python3` (stdlib only, no packages): runs the host-side credential proxy
  (see [security notes](docs/security.md)).
- A git push credential (**at least one** is required):
  - `ssh-agent` running with your key added (`ssh-add -l` lists it). The
    container only ever sees a forwarded agent socket, never your private
    key, but it dies with your client connection, so it's fine for
    interactive use, not for unattended/headless sessions.
  - `[core] ssh_key`: a dedicated deploy key for headless/unattended use,
    independent of any forwarded agent. See
    [Headless git push without agent forwarding](docs/configuration.md#headless-git-push-without-agent-forwarding).

Everything else is optional, depending on which workflow(s) you want. All of
it lives in one file, `~/.config/dejima/config`; `./install.sh` writes a
starter copy with every key present, commented out at its default; uncomment
and edit whichever ones you need. Run `dejima --print-config` at any time to
see the whole resolved schema, real values included.

| Key | Default | Purpose |
| --- | --- | --- |
| `[core] harness` | `claude-code` | agent harness the container runs |
| `[core] forge` | `none` | forge integration: `gitea` (`gitea-pr`/`gitea-issue`), `github` (`gh`, opens `ssh.github.com:22` for push), or `none` (no forge at all) |
| `[core] workflow` | `local-only` | workflow `sandbox-context.sh` tells the agent to follow: `worktree-pr` (push + open a PR), `branch-push` (push, stop at the branch), or `local-only` (commit locally, push nothing) |
| `[core] command` | `claude` | container's main process (e.g. `nvim`), also settable per launch with `--cmd` |
| `[core] firewall` | `on` | egress firewall; `off` disables it (debugging only), also settable per launch with `--no-firewall` |
| `[core] share_dir` | `~/.local/share/dejima/shared` | host-visible read/write scratch dir, mounted at `~/shared` |
| `[core] ssh_key` | unset | dedicated deploy key for headless/unattended git push |
| `[core] known_hosts` | `~/.ssh/known_hosts` | known-hosts file used for git-over-ssh |
| `[harness.claude-code] projects_dir` | `~/.claude/projects` | where Claude Code session transcripts live |
| `[harness.claude-code] statusline_path` | `~/.claude/statusline.sh` | statusline script path |
| `[forge.gitea] ssh_host` | unset | Gitea/Forgejo SSH hostname: skip if you only push to GitHub |
| `[forge.gitea] api` | unset | `https://<gitea host>/api/v1`: skip if you only push to GitHub |
| `[forge.gitea] token_file` | `~/.config/gitea/token` | path to the Gitea/Forgejo API token (the file, not the token itself) |
| `[forge.github] push_token_file` | unset | path to a **write-capable** PAT, used only when `[core] forge = github`: deliberately separate from `[github] token_file` below; see "GitHub push" in docs/security.md |
| `[github] token_file` | `~/.config/gh/sandbox-token` | path to a read-only PAT for private GitHub repos / `gh` |
| `[mounts] readonly` | unset | extra host paths (colon-separated) a personal config needs, mounted read-only at their own path |
| `[mounts] read_write` | unset | host paths (colon-separated) mounted **read-write** at their own path: for directories meant to outlive the session; refused if they overlap anything dejima needs out of a session's reach |
| `[mounts] nvim_config` | unset | nvim config dir, used when `[core] command = nvim` |
| `[credentials] proxy` | `on` | host-side credential proxy; `off` mounts the real OAuth credential into the container directly, as before this feature |
| `[credentials] transport` | `tls` | set to `loopback` to fall back to a plaintext forwarder with an explicit `ANTHROPIC_BASE_URL`, keeping the credential out of the container but reinstating the base-URL fingerprint: for when certificate pinning breaks the default TLS path (see [security notes](docs/security.md)) |
| `[logging] loki_url` | unset | ship DNS/firewall logs to a Loki endpoint |
| `[logging] conversation` | `off` | opt-in: also ship session transcripts to Loki (needs `loki_url`); see "Conversation logging (opt-in)" in docs/security.md |
| `[audit] dir` | `~/.local/share/dejima/audit` | where exit-time audit findings are stored |
| `[audit] baselines_dir` | `~/.local/share/dejima/baselines` | where audit baselines are stored |
| `[audit] keep` | `10` | how many past findings/baselines to retain |
| `[audit] strict` | `off` | refuse a headless (non-tty) launch over unacknowledged CRITICAL findings |
| `[remote-access] enabled` | `off` | the switch: nothing in "Remote access" below runs until this is `on` |
| `[remote-access] ntfy_url` | unset | ntfy topic URL for session notifications |
| `[remote-access] base_url` | unset | public URL of the web front door, for notification links |
| `[remote-access] ttyd_port` | `7681` | port `ttyd` listens on |
| `[remote-access] ttyd_font_size` | unset | `ttyd` terminal font size |
| `[remote-access] debounce` | `60` | seconds between repeat notifications for the same session |

**No forge is the default** (`[core] forge = none` with
`[core] workflow = local-only`): the sandbox commits locally and pushes
nowhere. A fresh install has no forge credentials, so defaulting to a pushing
pair would be claiming a setup that isn't there, and a pushing workflow whose
forge resolves to no host is refused at launch, which would make an
out-of-the-box `dejima` refuse to start. Pushing is something you opt into.

> **Changed default (was `gitea` + `worktree-pr`).** If your
> `~/.config/dejima/config` has no explicit `[core] forge` / `[core] workflow`
> lines, it used to resolve to `gitea` + `worktree-pr` and now resolves to
> `none` + `local-only`: your sandbox will stop pushing and stop opening PRs.
> To keep the old behaviour, write both lines out under `[core]`:
> `forge = gitea` and `workflow = worktree-pr` (and fill in `[forge.gitea]`,
> which that pair has always required). `./install.sh` prints this notice
> when it finds a config in that state.

To push, set `[core] workflow` to `worktree-pr` (push + open a PR) or
`branch-push` (push, stop at the branch), and pick the forge to push to:
`[core] forge = gitea` for a Gitea/Forgejo instance (fill in `[forge.gitea]`
per "Gitea/Forgejo PR workflow" below), or `[core] forge = github` to push and
open PRs through `gh` (see "GitHub push" in docs/security.md for the posture
change that opens, and why its `push_token_file` is a separate credential from the
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
hardcoded into dejima: each is a directory under `forges/`, `workflows/` or
`harnesses/`, selected independently by `[core] forge`, `[core] workflow` and
`[core] harness`. Ships today: `forges/gitea`, `forges/github`, `forges/none`,
`workflows/worktree-pr`, `workflows/branch-push`, `workflows/local-only`,
`harnesses/claude-code`. The defaults are `forges/none` and
`workflows/local-only`: a fresh install commits locally and pushes nowhere.

See [docs/providers.md](docs/providers.md) for the manifest contract, key by
key, and the shipped providers as worked examples.

## Setup

Every feature's configuration, in one place and in order. Each step links to
the section that explains *why* it is that way; this section only says what
to do. Only the first block is required - the rest are independent, so take
the ones you want and skip the rest.

For remote access, the reading is not optional: one of its steps is a full
sandbox escape if you get it wrong.

### Core (required)

1. `./install.sh`: symlinks the CLIs into `~/.local/bin` and the hooks into
   `~/.claude/hooks`, and writes a starter `~/.config/dejima/config` if none
   exists yet. It is idempotent, so re-run it after pulling; it never
   overwrites an existing config.
2. Put `~/.local/bin` on your `PATH` if it isn't already.
3. Give it a git push credential: `ssh-add` your key for interactive use,
   or set `[core] ssh_key` in the config to a dedicated deploy key for
   unattended runs.
   → [Prerequisites](#prerequisites),
   [Headless git push without agent forwarding](docs/configuration.md#headless-git-push-without-agent-forwarding)

That is enough to run `dejima`. The starter config `install.sh` writes has
every key commented out at its default, which means `[core] forge = none` and
`[core] workflow = local-only`: the agent works in the sandbox and commits
locally, and nothing is pushed anywhere. To have it push, pick a forge,
Gitea/Forgejo below or GitHub in the table below, and set `[core] workflow`
to `worktree-pr` or `branch-push`: a pushing workflow is refused at launch unless its forge
resolves to somewhere to push to, so the forge is not optional once you
choose one of them.

### Gitea/Forgejo PR workflow

Skip this if you use `forge = github` or `forge = none` instead, covered in
the table below.

1. Set `[forge.gitea] ssh_host` (the SSH hostname) and `[forge.gitea] api`
   (`https://<gitea host>/api/v1`) in `~/.config/dejima/config`.
2. Generate a token (Settings → Applications, scopes `write:repository` and
   `write:issue`) and save it to `~/.config/gitea/token`, `chmod 600`.
   → [Prerequisites](#prerequisites)

### Optional, once the above works

| Turn on | What it costs | Where |
| --- | --- | --- |
| GitHub instead of Gitea | Opens `ssh.github.com:22` for push whenever the selected workflow actually pushes, not just for one launch | [providers.md](docs/providers.md#shipped-providers) |
| No push at all | - | [providers.md](docs/providers.md) |
| Per-project domains and dependencies | - | [configuration.md](docs/configuration.md) |
| Log shipping to Loki | Opt-in conversation logging ships what you and the model actually say | [security.md](docs/security.md) |
| GitHub push over SSH | Much broader than it looks with a forwarded personal agent | [security.md](docs/security.md) |
| Remote access | One step is a full sandbox escape if you get it wrong | [remote-access.md](docs/remote-access.md) |

## Usage

Run `./install.sh` first; it symlinks the CLIs into `~/.local/bin` and the
hooks into `~/.claude/hooks`, and everything below assumes those are on your
`PATH`. See [Setup](#setup) for the rest of the first-run steps.

```sh
dejima                        # sandbox the current directory
dejima ~/repos/some-project
```

By default the container's entry point is bare `claude` (always running with
`--dangerously-skip-permissions`, regardless of how it's invoked; see
`docker/claude-wrapper.sh`), so a fresh clone of this repo works with no
editor setup at all.

Typical loop: point it at a project, ask for a change, and let the session
work. It commits to a feature branch, pushes it, and opens a pull request;
then it stops. You review and merge that PR yourself, wherever you normally
read them.

`merge-guard.sh` and `git-push-guard.sh` are fast-fail guards against an
overeager agent, not a boundary against a hostile one: a session holds the
forge token in its environment and could call the merge endpoint directly,
and the merge guard itself is per-workflow, inert unless that workflow turns
it on. Branch protection on the remote is what actually stops a merge from
happening without you.

That boundary is the shape of the loop rather than a limit on it: every
session ends at something you read before it lands.

**→ [docs/configuration.md](docs/configuration.md#the-session-briefing)** -
the guards in full, and why they fail open.

How far the session goes is the `[core] workflow` setting: `worktree-pr`
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

`~/shared`, the project mount, and anything in `[mounts] read_write` are the
only writable host paths in the container. Everything else a session writes
goes away with it.

**→ [docs/configuration.md](docs/configuration.md#shared-scratch-space)** - when to use
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

Outbound network access is default-deny: on start, the container builds an
allowlist-only `iptables`/`ipset` firewall, and anything not explicitly
allowed is rejected outright. The allowlist covers what the sandbox itself
needs to function - DNS resolution, the Docker host, GitHub on port 443 for
read access no matter which forge is selected, whatever the selected forge
itself needs reachable, the harness's own update and model endpoints,
`release-assets.githubusercontent.com` for GitHub release assets, and
`api.anthropic.com` when the credential proxy is off - plus whatever a
project has declared and had approved (see
[Global and per-project domains and dependencies](#global-and-per-project-domains-and-dependencies)
below). IPv6 is blocked outright too, with no allowlist equivalent for it.

DNS is allowlisted as well as IPs: a local resolver only forwards lookups
for names already on that same allowlist, so a domain that isn't approved
does not resolve at all, closing off exfiltration through query names and
not just through a direct connection. A blocked connection is refused
immediately rather than left to time out, so a session is told when
something doesn't connect instead of being left to guess.

Run `dejima-allow --global <domain>` (or `--project <path>`) to approve a
domain for future sessions - these deliberately do not touch a running container.
`dejima-allow <domain>` with no scope flag patches a domain into a session
that's already running instead. `dejima --no-firewall` disables the
firewall for one launch (debugging only).

**→ [docs/security.md](docs/security.md#network-egress-firewall)** - how the
ipsets are built, how `dnsmasq` is configured, and the NFLOG groups behind
the request log below.

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

If `[logging] loki_url` is set (see Prerequisites), every DNS query and
every new outbound connection attempt - allowed or rejected - is shipped
there, and, opt-in, the session transcript alongside them. This is
visibility on top of the firewall/DNS-proxy enforcement above, not a
substitute for it.

**→ [docs/security.md](docs/security.md#network-request-logging)** - the log
sources, opt-in conversation logging, and viewing both in Grafana.

## GitHub push: blocked by default, optional opt-in

The sandbox can always read from GitHub - clone, fetch, `gh` API calls. By
default it can never push there: GitHub's IP ranges are only allowlisted on
port 443, so port 22 is physically unreachable, not merely discouraged by a
hook.

Pass `--allow-github-push` to open port 22 for that one launch, paired with
a repo-scoped deploy key in `[core] ssh_key` rather than a forwarded
personal agent. The one exception is `[github] token_file`: pointed at a
write-scoped token instead of a read-only one, it enables HTTPS push over
port 443 independently of this flag, so keep it read-only.

**→ [docs/security.md](docs/security.md#github-push-blocked-by-default-optional-opt-in)**
- what a forwarded personal agent changes, and the persistent alternative.

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

Merging is a decision you make *after* the code has already run, and it does
not take a modified workflow file to get there: a workflow that runs a test
suite runs every file in it.

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

## Docs

| Doc | What is in it |
| --- | --- |
| [responsible-use.md](docs/responsible-use.md) | How to use this without making things worse |
| [security.md](docs/security.md) | Provider trust, the egress firewall, identity, and logging |
| [configuration.md](docs/configuration.md) | Per-project declaration, dependencies, config parity |
| [providers.md](docs/providers.md) | Forge, workflow and harness axes, and writing your own |
| [ci.md](docs/ci.md) | What push access grants on your CI host, and how to bound it |
| [remote-access.md](docs/remote-access.md) | Picking and verifying a bind address, and the SSH and web front doors |
| [development.md](docs/development.md) | The file map, the test suites, running them |

## License

This project is licensed under the GNU General Public License v3.0 or later
(GPL-3.0-or-later); see [LICENSE](LICENSE) for the full text.

Copyright (C) 2026 Brad Anderson
