<!-- Fixed, not preference-aware, and that is the decision rather than an
     oversight. `prefers-color-scheme` reports the browser's setting, never the
     site's, and this is read on a forge that renders dark whichever way the
     browser is set - so anything conditional shows dark ink on a dark page to
     a reader whose browser prefers light, and does it silently.
     The suffix names the mode a file is FOR, not the colour of its ink:
     -darkmode is the pale wordmark that belongs on a dark page. A mirror on a
     light-themed host swaps the filename below for dejima-wordmark-lightmode.png,
     which is committed alongside for exactly that. One line, on the mirror,
     where someone can see whether it worked.
     Every &nbsp; here is spacing, and it has to be a character rather than CSS
     or a presentation attribute. Gitea's sanitizer strips `style` from the tag
     and from any wrapper, `hspace`/`vspace` survive sanitizing only to be
     ignored by browsers that dropped HTML4 presentation attributes, and a bare
     <br> ends a line nothing follows, which browsers collapse to no height.
     &nbsp; survives as a real U+00A0: on its own line it fills a paragraph
     that would otherwise be empty, and immediately before the tag it sits
     inline and indents the image by one space. -->
&nbsp;

&nbsp;<img src="assets/dejima-wordmark-darkmode.png" alt="dejima" height="72">

---

&nbsp;

**Agents work best without you babysitting them. Bound the blast radius, let them
work, and assume they are hostile.**

Most sandboxes stop at the container. The blast radius does not. A contained
session still opens pull requests, and your CI runs that commit before anyone
reads it; an escape from the container lands on a machine with its own reach
across your network. **dejima puts a control on every layer it passes
through.**

dejima is a **sandboxed development environment for unsupervised agentic
work**: a coding agent running with its permission prompts off, inside a
firewalled Docker container, against a project bind-mounted from your host.
Claude Code and Cline today, selected in the config, and neither is a default.
A prompt injection or a poisoned dependency can turn it mid-session and it will
not announce that, so what it can reach, take and break is decided before it
starts.

**What bounds it:**

- **An egress allowlist.** DNS and IP, IPv4 and IPv6. Anything not on the
  list does not connect, and the agent is told so.
- **Credentials that stay on the host.** Your model credential never enters
  the container, whichever backend you selected: a host-side proxy holds it
  and injects it per request, and the container gets a placeholder. Your SSH
  key doesn't either; the container sees an agent socket, never the key.
- **Per-project declaration and approval.** A project declares the domains
  and dependencies it needs in `.dejima/`. Declaring is not granting: the
  approval is a separate decision you make on the host, and the approval
  store is never mounted where a session could reach it.
- **One project's session cannot reach another's.** Your harness's state
  directory is not mounted whole. A session gets its own project's
  transcripts, memory and edit history and nothing else, so it cannot read
  what you did elsewhere or write into another project's memory.
- **CI hardening, because push access is code execution elsewhere.** A session
  opens a pull request, the workflow fires, and your runner executes that
  commit before you've read a line of it. The container bounds what a session
  reaches directly, not what it can arrange to have run somewhere else. See
  [docs/ci.md](docs/ci.md) for what hardening a runner takes, and
  [dejima-ci-hardener](https://gitbox.branderson.io/dejima/dejima-ci-hardener)
  for a tool that does it.
- **Guard rails inside the session.** Pushes to anywhere but the allowed
  remote, and merging a PR from inside the sandbox, are refused whichever
  harness is selected - they shadow `git` and the forge CLI on `PATH`. Refusing
  an obviously destructive command needs a hook the harness can host, so a
  harness without one goes without it, and the launch says so rather than
  leaving you to assume. All of these are fast-fail guards against an
  overeager agent, not a boundary against a hostile one: the container is the
  boundary.
- **An exit-time audit** of the host surfaces a session could have written to,
  so a change to your git config, to the workspace's own agent configuration,
  or to a file your harness runs on the host does not go unnoticed.

**What it gives an agent to work with:**

- **A PR and issue workflow the agent drives itself.** `gitea-pr` and
  `gitea-issue` open pull requests and issues against Gitea or Forgejo and pull
  review feedback back in, on a token scoped for exactly that; on GitHub the
  same work goes through `gh`. Merging stays a human decision, made outside the
  sandbox.
- **Project context written for the agent.** A project ships a `.dejima.md`
  saying how work is done in it - `CLAUDE.md`'s job under a harness-agnostic
  name - and dejima loads it alongside a briefing on where the session is and
  why the limits are there. An agent that knows it is in a sandbox asks for a
  domain rather than working around the firewall.
- **Config parity with your host.** Your harness's own global instructions,
  settings, hooks, skills, rules and plugins carry over, and so does your git
  identity; uid, home directory and project path match on both sides, so a
  session's transcript is readable from the host afterward.
- **Remote access, opt-in and off by default.** Attach to a live session from
  a terminal or a browser, with a push notification when it wants you.
- **What a long session worked out, kept.** Each time the agent compacts, the
  summary it writes is saved host-side, into a store no container mounts. It
  is otherwise the only account of a session's reasoning, and it goes when the
  container does.
- **Logging, off unless you turn it on.** Point `[logging] loki_url` at your
  own Loki instance and every DNS lookup and rejected connection is shipped
  there, with the session transcript too if you separately opt in. Nothing
  leaves the machine otherwise, and there is no endpoint of ours anywhere in
  this.

**Early development. Not ready to be depended on.** Nothing here has been
through outside review, an external audit, or adversarial testing by anyone
but the person who wrote it. Every security property this describes is a
claim awaiting scrutiny, not one that has survived it. Do not put this
anywhere that being wrong about it would matter.

**One maintainer, no support.** Nothing about this is promised: not a reply,
not a fix, not a release. [SECURITY.md](SECURITY.md) has the detail, and is
where to report a vulnerability rather than in a public issue.

A note from the developer about the voice in this repository:

> dejima is developed in dejima, and that means the words are written rapidly
> by AI agents. That applies to this README, the docs, the commit messages,
> the pull requests, and the code comments. I periodically take passes at
> smoothing out the AI voice in the docs, but it's inefficient to do with
> every pull request. I'm prioritizing thorough documentation over human
> voice. If you feel something sounds painfully "AI", it is.
>
> The artwork (logo, wordmark, etc.) is a different story. It's made by a
> human, and no AI tools were used to create it. See
> [ATTRIBUTION.md](ATTRIBUTION.md).

[![Developed in dejima](assets/dejima-badge.svg)](https://gitbox.branderson.io/dejima/dejima)

## The dejima stack

dejima runs inside the machine it is protecting the rest of, so it cannot bound
its own host, a runner it never touches, or notice anything after a session
ends. These are what cover the rest. **Only the first row is required.** The
last two are categories rather than products; the named ones are what this
deployment happens to use.

| Piece | Runs on | What it adds |
| --- | --- | --- |
| **dejima** | a devbox | The container boundary: what a session reaches on disk, and deny-by-default egress. |
| **[dejima-devbox-hardener](https://gitbox.branderson.io/dejima/dejima-devbox-hardener)** | the same devbox | Cuts LAN reach to what is declared, enforced from outside the guest so root in the VM cannot flush it. |
| **[dejima-guard](https://gitbox.branderson.io/dejima/dejima-guard)** | a different machine | Notices the devbox changed, against a baseline held off the box. Detection, not enforcement. |
| **[dejima-ci-hardener](https://gitbox.branderson.io/dejima/dejima-ci-hardener)** | your CI runner | A runner that executes a session's pull request without that being LAN access. Hosted CI is the alternative, on someone else's network rather than yours. |
| **ntfy**, or any push service | anywhere both can reach | Where "session needs input" and the guard's alerts arrive. |
| **Uptime Kuma**, or any uptime monitor | off the devbox | The dead man's switch: what notices the guard itself stopped reporting. |

**→ [docs/threat-model.md](docs/threat-model.md#the-stack-and-what-each-piece-buys)** -
what each one buys, what goes wrong without it, and where each one's boundary
ends. None of them is required to run dejima; what they change is what the
layer below the container costs, and whether anyone finds out.

**→ [Using dejima on its own](docs/threat-model.md#using-dejima-on-its-own)** -
what holds without them, what does not, and what to do about it.

**→ [Why a container, and not a microVM?](docs/threat-model.md#why-a-container-and-not-a-microvm)** -
the most common question about this design, and why the effort went into the
layers below the container rather than into a harder one.

## Setup

This repo only holds the tooling; no project lives here. Point it at a project
on disk and that project is bind-mounted into the container at runtime.

**Prerequisites:** Docker with the `docker compose` v2 plugin, `jq`, and
`python3` (stdlib only, no packages) for the host-side credential proxy.

Only the first block below is required. The rest are independent, so take the
ones you want.

### Core (required)

1. **Install your harness on the host**, and sign in to it there if it needs a
   credential. dejima never authenticates anything: the credential proxy holds
   what your harness wrote on the host and hands the container a placeholder,
   so if there is nothing on the host there is nothing to hold. See
   [Sign in on the host first](#sign-in-on-the-host-first) - and skip it
   entirely for a harness pointed at a model you serve yourself, which needs
   no credential.
2. **`./install.sh`**, which symlinks the CLIs into `~/.local/bin` and writes
   a starter `~/.config/dejima/config` if none exists. It writes nothing to
   your harness's own config: the sandbox's guards are baked into the image and
   registered per launch into a settings layer of dejima's own, so installing
   dejima does not change how your harness behaves outside a sandbox.
   Idempotent, so re-run it after pulling; it never overwrites an existing
   config.
3. **Put `~/.local/bin` on your `PATH`** if it isn't already.
4. **Set `[core] harness`.** It has no default and a launch is refused without
   it, which is what stops a later release changing your selection for you. The
   starter config states `claude-code`, because a file with no default to fall
   back on has to name a choice; change that line for Cline.

That is enough to run `dejima`, and no push credential is needed to get this
far. Everything else runs at its default, which means `[core] forge = none` and
`[core] workflow = local-only`: the agent works in the sandbox and commits
locally, and nothing is pushed anywhere.

**Those defaults are pinned to this machine, once.** The first launch writes
them to `~/.config/dejima/defaults.conf`, which your own config overrides, so
a later release cannot move a setting you never chose. `./install.sh` adds keys
a release introduced and names any shipped default that has moved, without
taking it.

**→ [docs/configuration.md](docs/configuration.md#configuration-reference)** -
every key, its default, and what it is for. `dejima --print-config` prints the
resolved schema at any time, real values included.

### Pushing to a forge

Set `[core] workflow` to `worktree-pr` (push a branch and open a pull request)
or `branch-push` (push, stop at the branch), and pick a forge to push to: a
pushing workflow is refused at launch unless its forge resolves to somewhere to
push.

It also needs a git push credential, and which one you give it matters:

- **`[identity.default] ssh_key`, a key of the session's own**, belonging to
  an account that is not you. This is the one to set up. It gives the sandbox
  an identity separable from yours, so what it pushes is visibly its work and
  the permissions you grant it are its permissions rather than all of yours. It
  also works unattended, which a forwarded agent does not. (`[core] ssh_key` is
  the same key under its old name, and still read.)
  → [Headless git push without agent forwarding](docs/configuration.md#headless-git-push-without-agent-forwarding)
- **`ssh-agent` with your own key added** (`ssh-add -l` lists it), as the
  fallback. The container sees a forwarded socket and never the private key,
  and the socket dies with your client connection. But the session is then
  authenticating **as you**: everything it pushes is yours, and it holds
  whatever that key can reach for as long as it runs.
  → [To your forge, the sandbox is you](docs/security.md#to-your-forge-the-sandbox-is-you)

For `forge = gitea`, set `[forge.gitea] ssh_host` and `[forge.gitea] api`
(`https://<gitea host>/api/v1`), then generate a token (Settings →
Applications, scopes `write:repository` and `write:issue`) into
`~/.config/gitea/token`, `chmod 600`. `forge = github` is in the table below.

### Optional, once the above works

| Turn on | What it costs | Where |
| --- | --- | --- |
| GitHub instead of Gitea | Opens `ssh.github.com:22` for push whenever the selected workflow actually pushes, not just for one launch | [providers.md](docs/providers.md#shipped-providers) |
| No push at all | - | [providers.md](docs/providers.md) |
| Per-project domains and dependencies | - | [configuration.md](docs/configuration.md) |
| Log shipping to Loki | Opt-in conversation logging ships what you and the model actually say | [security.md](docs/security.md) |
| GitHub push over SSH | Much broader than it looks with a forwarded personal agent | [security.md](docs/security.md) |
| Remote access | One step is a full sandbox escape if you get it wrong, so the reading is not optional | [remote-access.md](docs/remote-access.md) |

## Usage

```sh
dejima                        # sandbox the current directory
dejima ~/repos/some-project
dejima --isolated             # no project at all - see below
```

Point it at a project, ask for a change, and let the session work. What happens
after that is the workflow you configured: `local-only` commits and pushes
nowhere, `branch-push` stops at the push, and `worktree-pr` pushes a branch and
opens a pull request, then stops. What holds across all three is where they
stop - **none of them puts work on your default branch**, so the last step is
yours in every case. That comes from how the workflows are arranged, not from
anything enforced against a session that does not want to cooperate.

The container's main process is whatever the selected harness declares, always
with that harness's own no-prompt flag applied regardless of how it is invoked
(see `docker/harness-wrapper.sh`).

dejima itself is developed under `worktree-pr`, so this repository is that
workflow in use: its branches and pull requests were opened by sessions running
in it, and merged by a human afterwards.

On a pushing workflow, `merge-guard.sh` and `git-push-guard.sh` are fast-fail
guards against an overeager agent, not a boundary against a hostile one. Hand a
session a forge token that can merge and it can call the merge endpoint
directly. The merge guard is per-workflow as a mechanism, and every workflow
dejima ships turns it on, so the switch exists for a third-party workflow
rather than as a choice among these. Branch protection on the remote, and a
token scoped to less than merge, are what actually stop a merge from happening
without you.

**→ [docs/configuration.md](docs/configuration.md#the-session-briefing)** -
the guards in full, and why they fail open.

### Configuring the session

A different editor or application (`--cmd`, `[core] command`,
`[mounts] nvim_config`) is a config-file change, as are the extra host
directories a session should reach: `[mounts] readonly` and
`[mounts] read_write`, mounted at their own path.

For a one-off, `--extra-readonly PATH` and `--extra-read-write PATH` (short
forms `--ro` and `--rw`, both repeatable) add a path for a single launch, for
things like reading another checkout while migrating code out of it:

```sh
dejima --ro ~/other-project ~/myproject
```

**→ [docs/configuration.md](docs/configuration.md#one-off-mounts-for-a-single-launch)** -
both forms, and which host paths a mount is refused over and why.

### A session with no project

`dejima --isolated` is the other direction: nothing of your machine is
mounted, no memory or transcript crosses either boundary, no forge credential
unless the same command names a forge, and the one thing that outlives the
session is a `~/shared` made fresh for it. Run it from anywhere - the
directory you are in is not used, and naming one is refused rather than
ignored, so a launch cannot look like it is working on a project it cannot
see.

It narrows what a session can read of the host and what credential it carries.
It is not a stronger sandbox: the firewall, the credential boundary and the
capability drops are what they are for every other session.

**→ [docs/configuration.md](docs/configuration.md#isolated-sessions)** - the
table of what differs, and what the mode gives up.

**Ctrl-Z backgrounds dejima's host side**, and `fg` brings back a working
session. It gets your terminal back rather than pausing the agent - the
container keeps running - so for a session you want to leave working and pick
up elsewhere, run dejima inside tmux and use
[`dejima-attach`](docs/remote-access.md).
→ [why that takes doing](docs/configuration.md#suspending-a-session)

## Sign in on the host first

**Install your harness on the host and authenticate it there before running
dejima.** Nothing enforces this, and getting it wrong does not look like a
missing prerequisite: `dejima` starts normally, the container comes up, the
firewall self-checks pass, and then the session cannot reach the model.

dejima signs in to nothing. The credential proxy's whole design is that the
credential stays on the host and the container gets a placeholder, which only
works if the host has a credential to hold. Authenticating from inside is not
the fix: the container is where the credential deliberately never goes, and the
egress allowlist is not built around completing a sign-in flow there. The same
applies to the account state your harness keeps alongside the credential, read
fresh from the host at every launch (Claude Code's is "Throwaway
~/.claude.json" in [docs/security.md](docs/security.md)).

So: run your harness once on the host, sign in, confirm it answers, and then
point dejima at a project. When a credential expires, refresh it the same way,
on the host rather than in a session.

**None of this applies to a harness pointed at a model you serve yourself.**
There is no credential to hold or expire; what that setup needs instead is for
the endpoint to be reachable from inside the container, which is an allowlist
question rather than a sign-in one.

## Provider axes: forge, workflow, harness, model backend

The forge integration, the push/PR workflow, the agent harness and the model
API aren't hardcoded into dejima: each is a directory under `forges/`,
`workflows/`, `harnesses/` or `backends/`, selected independently by
`[core] forge`, `[core] workflow`, `[core] harness` and
`[harness.<name>] backend`.

- **Forges:** `none`, `gitea`, `github`
- **Workflows:** `local-only`, `branch-push`, `worktree-pr`
- **Harnesses:** `claude-code`, `cline`
- **Model backends:** `anthropic`, `anthropic-api-key`, `openrouter`, `self-hosted`

Which of those last two pair up is the backend's API dialect against the
harness's, checked at launch rather than maintained as a list:

| Backend | `claude-code` | `cline` | Credential |
| --- | --- | --- | --- |
| `anthropic` | yes | yes | OAuth, held on the host |
| `anthropic-api-key` | yes | yes | a static key, held on the host |
| `openrouter` | no | yes | a static key, held on the host |
| `self-hosted` | no | yes | none, and so no proxy at all |

**→ [docs/providers.md](docs/providers.md)** - the manifest contract, key by
key, what each pairing needs configured, and the shipped providers as worked
examples. The model API is called a *backend* throughout, to keep it apart
from the axes themselves.

## Using this responsibly

dejima bounds what a session can reach. Whether what that session wrote should
exist is your call.

- **Check whether the project wants it first.** A growing number of projects
  state that they do not accept AI-assisted contributions. Read the
  CONTRIBUTING before you start, not after; dejima has
  [its own](CONTRIBUTING.md).
- **Don't point it at repositories you don't own.** Maintainers are already
  drowning in low-effort AI pull requests. Fork the project, point dejima at
  your fork, and open the upstream PR yourself once you would have been happy
  to have written it by hand.
- **Don't point it at proprietary code**, or at a directory holding a stray
  `.env`, a database dump or a key. The whole directory is mounted read-write,
  so whether your *code* is sensitive is the easy half of the question.
- **An allowlist entry is a grant, not a convenience.** Your production API, a
  deploy webhook or a payment provider gives an unattended agent the ability to
  act on the world, and unlike code that never passes through a diff on its way
  out. Allowlist things that can be wrong without being expensive.
- **Give it its own identity, then own what you merge.** A session should
  authenticate to your forge as itself, not as you
  ([how](docs/security.md#to-your-forge-the-sandbox-is-you)). Agents write
  insecure and broken code, prompt injection is not solved, and supply-chain
  malware arrives through allowlisted sources. Keeping that out of `main` is
  your job, not the container's, and people reading your `main` will hold you
  to it whoever's name is on the commit.
- **Understand what you ship.** dejima makes development fast enough that not
  reading the diff gets tempting. A good model is not a substitute for
  engineering judgement or human review, and nothing here changes that.
- **This is not a blastproof box.** It is an improvement over running an agent
  directly on your machine, and a determined attacker, or one with a container
  escape, defeats all of it. An escape does not leave the picture, it moves to
  the layer below, which dejima cannot bound because it runs inside it.
  [dejima-devbox-hardener](https://gitbox.branderson.io/dejima/dejima-devbox-hardener)
  bounds that layer; [docs/threat-model.md](docs/threat-model.md) says where
  each layer's compromise stops.
- **dejima's security says nothing about your software's.** Security isn't
  retrofittable. If what you build inside dejima turns out to be insecure, that
  isn't something a sandbox could have prevented.

→ **[docs/responsible-use.md](docs/responsible-use.md)** for the reasoning
behind each of these, and the fork-and-review workflow in full.

## Network egress firewall

Outbound access is default-deny: the filter container establishes an
allowlist-only `nftables` policy at start, and anything not explicitly allowed
is rejected outright rather than left to time out, so a session is told when
something doesn't connect rather than waiting out a timeout and reporting a
broken tool. IPv6 is refused outright rather than allowlisted: a sandbox has no
IPv6 egress at all, and one table states that in the same transaction as
everything else, so there is no moment where the family is partly filtered.

The allowlist covers what the sandbox needs to function - DNS, the Docker host
on the ports a host-resident service was configured on and no others,
GitHub on port 443 for read access whichever forge is selected, whatever the
selected forge needs, the harness's own update endpoints, and the selected
backend's API endpoint when the credential proxy is off - plus whatever a
project has declared and had approved. With the proxy on that last name is
deliberately absent: the session reaches the API through the in-container
terminator rather than by resolving it.

DNS is allowlisted as well as IPs: a local resolver only forwards lookups for
names already on that same allowlist, so an unapproved domain does not resolve
at all, closing off exfiltration through query names and not just through a
direct connection.

```sh
dejima-allow --global crates.io       # for future sessions, every project
dejima-allow --project ~/myproject crates.io
dejima-allow crates.io                # patch a session already running
```

The scope flags deliberately do not touch a running container; the bare form is
the one that patches a live session. `dejima --no-firewall` disables the
firewall for one launch (debugging only).

**→ [docs/security.md](docs/security.md#network-egress-firewall)** - how the
address sets are built, how the resolver is restricted, and the two records
behind the request log below.

## Global and per-project domains and dependencies

A project declares the domains and dependencies it needs in two committed
files, `.dejima/allowed-domains` and `.dejima/dependencies`, stacked through a
global layer and, for domains, a container-only layer for one running session.

**Declaring grants nothing.** The project directory is bind-mounted read-write,
so a compromised session could write these files itself; they are read only to
compare against reality and suggest a command. Approval is a separate act you
do yourself on the host:

```sh
dejima-project approve ~/myproject    # review and approve the declared set
dejima-dep add --global cargo:cargo-nextest
```

The approval store lives under `~/.config/dejima/` by default and is never
mounted where a session could reach it, so nothing written to `.dejima/` from
inside the sandbox can approve itself. And
`dejima-project approve` never attempts to patch a running session: it records
approvals, and they take effect at the next launch. A session whose project
declares something it doesn't have is told so in its startup context, with the
exact command to hand you.

**→ [docs/configuration.md](docs/configuration.md)** - the full layering,
tarball dependencies, the symlink refusal that protects the approval store,
and the complete `dejima-allow`/`dejima-dep`/`dejima-project` reference.

## Config parity with your host harness setup

Your harness's own global instructions, settings, hooks, skills, rules and
plugins carry over, along with your git identity, and your existing login stays
effective with the credential itself never entering the container. The
harness's config directory is not shared as a whole - only an enumerated subset
is, so a session transcript is readable from the host afterward but a
credential or cache isn't. The container's own user matches yours exactly, so
`$HOME`-relative paths resolve the same on both sides.

Which files those are is each harness's own question, answered in its plugin:
`~/.claude` for Claude Code, `~/.agents` and `~/.cline` for Cline.

**→ [docs/configuration.md](docs/configuration.md)** - exactly what carries
over and what doesn't, per harness, and why single-file mounts couldn't be
trusted here.

## Shared scratch space

`~/shared` is a read-write bind mount of this project's directory under
`[core] share_dir`, separate from the project mount, for passing files in and
out of a session without touching the checkout. One directory per project, so a
session sees its own project's handoff files and no other project's.
`dejima-share path` prints the host directory to drop a file into before a
launch; `dejima-share list` shows what every project is holding.

It persists across sessions since it's a real directory, not a container
volume. **Clear it out between sessions:** anything left there is readable by
the next session against that project, and by every session after that.

`~/shared`, the project mount, and anything in `[mounts] read_write` are the
only writable host paths in the container. Everything else a session writes
goes away with it.

**→ [docs/configuration.md](docs/configuration.md#shared-scratch-space)** - when
to use `[mounts] read_write` instead, for anything meant to outlive the session
at a fixed host path.

## Sandbox self-awareness

`.dejima.md` at a project's root is that project's agent-instruction file, the
harness-agnostic equivalent of `CLAUDE.md`, loaded into the session's context
with no authority over the sandbox itself. dejima also briefs the
session on where it is running and on the instructions belonging to whichever
workflow you selected, so a session under `local-only` is told something
different from one under `worktree-pr`.

**→ [docs/configuration.md](docs/configuration.md)** - `.dejima.md` in full,
and everything the session briefing covers.

## Testing frontend changes

Playwright (Chromium) is pre-installed at image build time, with no network
access or per-project `npm install playwright` needed. `localhost`/loopback
traffic never goes through the egress firewall, so a project's own dev server
needs no firewall changes; a real external site still needs to be on the
allowlist like any other network use.

**→ [docs/configuration.md](docs/configuration.md)** - Playwright's own CDN
download, and why Chromium's process sandbox isn't active in this image.

## GitHub push: blocked by default, optional opt-in

A session that is not being used to push to a forge should not be able to push
to it. Your configured forge is the one you chose; GitHub is where everything
else lives - every dependency a session reads, every repository it clones to
understand an error. The case this prevents is an eager agent, not a
compromised one: an unsolicited pull request on a stranger's project, in your
name, on a queue its maintainers are already drowning in.

The sandbox can always read from GitHub. By default it can never push there:
GitHub's IP ranges are only allowlisted on port 443, so port 22 is physically
unreachable rather than merely discouraged by a hook. Two properties carry
that, both worth naming because the claim stays readable if either quietly
stops being true. The restriction belongs to the *destination* rather than to
the path it was reached by, so resolving a GitHub name cannot open a port its
published ranges do not have. And IPv6 is refused as a whole family, because an
allowlist naming one address family says nothing about the other - so "port 22
is closed on those ranges" would mean nothing if a v6 route to the same host
stayed open. The refusal is the first rule of the chain and there is no v6
permit path anywhere in it, which the policy checks at startup rather than
assuming.

`--allow-github-push` opens port 22 for one launch, paired with a repo-scoped
deploy key in `[core] ssh_key` rather than a forwarded personal agent. The one
exception is `[github] token_file`: pointed at a write-scoped token, it enables
HTTPS push over port 443 independently of that flag, so keep it read-only.

**→ [docs/security.md](docs/security.md#github-push-blocked-by-default-optional-opt-in)** -
what a forwarded personal agent changes, and the persistent alternative.

## Exit-time audit

Before each run, dejima snapshots the host surfaces a session could write to
and persist through: `.git/config` keys that run a command on the next `git`,
`.git/hooks/`, the workspace's `.claude/` and `.vscode/`, `.mcp.json`, `.envrc`,
and any host-side file the selected harness declares as one it runs by itself.
After the container exits it diffs them and tells you what changed.

It is **advisory, not a block**, firing after the session has ended, so a
finding is something to clean up before your next `git` command or session in
that repo. Its findings are a time window, not a verdict on who caused them:
one says a path changed while the session was running.

`dejima-audit show` indexes what is waiting and `dejima-audit ack` walks it, one
finding at a time. `[audit] strict` refuses a headless launch while CRITICAL
findings are unacknowledged, which is what turns the audit from a report into a
gate for unattended runs.

**→ [docs/security.md](docs/security.md#the-exit-time-audit)** - every surface
it watches, what it cannot see, and how the baseline works.

## Remote access

**Opt-in, and off entirely unless `[remote-access] enabled = on` is set in
`~/.config/dejima/config`.** Reach a running sandbox from another machine or a
phone, over SSH or a browser, and get a push when a session wants you. Two front
doors and a notification path, none of which exist until you configure them.

It is documented separately because getting the bind address wrong is the one
mistake here that exposes a no-prompt agent shell to your network.

**→ [docs/remote-access.md](docs/remote-access.md)** - `[remote-access]`,
picking a bind address and verifying it, the SSH and web front doors, reading
and typing on a phone, running behind another reverse proxy, notifications, and
attaching.

## Network request logging

If `[logging] loki_url` is set, every DNS query and every new outbound
connection attempt - allowed or rejected - is shipped there, and, opt-in, the
session transcript alongside them. This is visibility on top of the
firewall/DNS-proxy enforcement above, not a substitute for it.

**→ [docs/security.md](docs/security.md#network-request-logging)** - the log
sources, opt-in conversation logging, and viewing both in Grafana.

## CI: push access is code execution elsewhere

Merging is a decision you make *after* the code has already run, and it does not
take a modified workflow file to get there: a workflow that runs a test suite
runs every file in it.

**This holds for projects with no CI, too** - a branch can add the first
workflow, so what matters is which runners the repository can *reach*, not what
it runs today. That is a property of the forge rather than the project, and it
is worth one question per project before you start. On hosted runners the answer
is reassuring; with self-hosted runners in reach it is the thing to look at. And
`[core] forge = none` with `[core] workflow = local-only` declines the push
grant and the code execution with it.

**→ [docs/ci.md](docs/ci.md)** - the *why*: no approval gate is offered and what
that leaves, hardening a runner, and making CI's egress allowlist a
version-controlled artifact read from `main`.

**→ [dejima-ci-hardener](https://gitbox.branderson.io/dejima/dejima-ci-hardener)** -
the *how*: a self-contained tool that hardens a CI runner, installed on the CI
box and nowhere near a dejima host. Nothing in this repository needs to be
copied onto a runner.

## Security notes

What this sandbox does and does not protect you from - the containment
boundary, what a compromised session can still reach, and the deliberate
trade-offs behind running an agent with no permission prompts.

**→ [docs/security.md](docs/security.md)**

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

## Tests

Every behaviour this README asserts is enforced by a test that fails when it
stops being true: that the firewall blocks what it says it blocks, that
credentials never enter the container, that a push to anywhere but the allowed
remote is refused. They are why the claims here are stated flatly.

→ **[docs/development.md](docs/development.md)**: the suites, what each covers,
and how to run them.

## Docs

| Doc | What is in it |
| --- | --- |
| [responsible-use.md](docs/responsible-use.md) | How to use this without making things worse |
| [security.md](docs/security.md) | Provider trust, the egress firewall, identity, and logging |
| [threat-model.md](docs/threat-model.md) | What is assumed hostile, and where each layer's compromise stops |
| [research-review.md](docs/research-review.md) | Checking the threat model against the field's, and the standing questions that are the agenda |
| [configuration.md](docs/configuration.md) | Per-project declaration, dependencies, config parity |
| [tools.md](docs/tools.md) | The optional tools a session can be given, and what hardening each one carries |
| [providers.md](docs/providers.md) | Forge, workflow, harness and model-backend axes, and writing your own |
| [ci.md](docs/ci.md) | What push access grants on your CI host, and how to bound it |
| [remote-access.md](docs/remote-access.md) | Picking and verifying a bind address, and the SSH and web front doors |
| [development.md](docs/development.md) | The file map, the test suites, running them |
| [SECURITY.md](SECURITY.md) | What dejima claims, where to report a vulnerability, and what is promised in return |
| [ATTRIBUTION.md](ATTRIBUTION.md) | Who holds the dejima marks and what may be done with them |

## License

This project is licensed under the GNU General Public License v3.0 or later
(GPL-3.0-or-later); see [LICENSE](LICENSE) for the full text.

Copyright (C) 2026 Brad Anderson

The dejima wordmark and logo are not code and are not covered by that licence.
They are trademarks; who holds them and what may be done with them is stated
once for the organisation, in [ATTRIBUTION.md](ATTRIBUTION.md).

