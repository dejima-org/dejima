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
  - `SANDBOX_SSH_KEY` — a dedicated deploy key for headless/unattended use,
    independent of any forwarded agent. See "Headless git push without
    agent forwarding" below.

Everything else is optional, depending on which workflow(s) you want:

| Variable | Default | Purpose |
| --- | --- | --- |
| `GITEA_SSH_HOST`, `GITEA_API` | unset | Gitea/Forgejo PR workflow (`gitea-pr`) — skip both if you only push to GitHub |
| `GITEA_TOKEN` | env, else `~/.config/gitea/token` | Gitea/Forgejo API token |
| `GH_TOKEN` | env, else `~/.config/gh/sandbox-token` | read-only PAT for private GitHub repos / `gh` |
| `ALLOW_GITHUB_PUSH` | `0` | opt-in: allow `git push` to GitHub (blocked by default — see below) |
| `SANDBOX_CMD` | `claude` | container's main process (e.g. `nvim`) |
| `SANDBOX_NVIM_CONFIG` | unset | nvim config dir, used when `SANDBOX_CMD=nvim` |
| `SANDBOX_EXTRA_MOUNTS` | unset | extra host paths (colon-separated) a personal config needs, mounted read-only at their own path |
| `SANDBOX_SHARE_DIR` | `~/.local/share/dejima/shared` | host-visible read/write scratch dir |
| `LOKI_URL` | unset | ship DNS/firewall logs to a Loki endpoint |
| `SANDBOX_LOG_CONVERSATION` | `0` | opt-in: also ship session transcripts to Loki (needs `LOKI_URL`) — see "Conversation logging (opt-in)" below |
| `ENABLE_FIREWALL` | `1` | set to `0` to disable the egress firewall (debugging only) |
| `SANDBOX_CREDENTIAL_PROXY` | `1` | set to `0` to disable the host-side credential proxy and mount the real OAuth credential into the container directly, as before this feature |
| `SANDBOX_ANTHROPIC_TRANSPORT` | `tls` | set to `loopback` to fall back to a plaintext forwarder with an explicit `ANTHROPIC_BASE_URL`, keeping the credential out of the container but reinstating the base-URL fingerprint — for when certificate pinning breaks the default TLS path (see [security notes](docs/security.md)) |

**Gitea/Forgejo is the default PR workflow** — `gitea-pr`, and the only push
target `git-push-guard.sh` allows by default. If you don't use Gitea/Forgejo,
skip `GITEA_*` entirely and set `ALLOW_GITHUB_PUSH=1` instead to push
straight to GitHub (see "GitHub push: blocked by default, optional opt-in"
below) — the two aren't both required, pick whichever matches your remote.
[Forgejo](https://forgejo.org/) works unmodified: it's a Gitea fork exposing
a compatible `/api/v1` surface, so pointing `GITEA_API` at a Forgejo instance
just works.

## Setup

Every feature's configuration, in one place and in order. Each step links to
the section that explains *why* it is that way; this section only says what
to do. Only the first block is required - the rest are independent, so take
the ones you want and skip the rest.

For remote access, the reading is not optional: one of its steps is a full
sandbox escape if you get it wrong.

### Core (required)

1. `./install.sh` — symlinks the CLIs into `~/.local/bin` and the hooks into
   `~/.claude/hooks`. It is idempotent, so re-run it after pulling.
2. Put `~/.local/bin` on your `PATH` if it isn't already.
3. Give it a git push credential — `ssh-add` your key for interactive use,
   or set `SANDBOX_SSH_KEY` to a dedicated deploy key for unattended runs.
   → [Prerequisites](#prerequisites),
   [Headless git push without agent forwarding](#headless-git-push-without-agent-forwarding)

That is enough to run `dejima`.

### Gitea/Forgejo PR workflow

Skip this if you only push to GitHub.

1. Export `GITEA_SSH_HOST` (the SSH hostname) and `GITEA_API`
   (`https://<gitea host>/api/v1`) from your shell profile.
2. Generate a token — Settings → Applications, scopes `write:repository` and
   `write:issue` — and save it to `~/.config/gitea/token`, `chmod 600`.
   → [Prerequisites](#prerequisites)

### Per-project domains and dependencies

Nothing to set up in advance; do this per project, as it turns out to need
something:

```sh
dejima-project status ~/myproject     # declared vs approved vs missing
dejima-project approve ~/myproject    # approve the declared set
dejima-allow crates.io --project ~/myproject
dejima-dep add cargo:cargo-nextest --global
```

Domains apply at the next launch, and `dejima-allow` also patches a running
session. Dependencies need an image rebuild, so they always land on the next
one. →
[Global and per-project domains and dependencies](#global-and-per-project-domains-and-dependencies),
[Adding a domain to a running session](#adding-a-domain-to-a-running-session)

### Log shipping

1. Export `LOKI_URL` pointing at your Loki push endpoint.
2. Optionally set `SANDBOX_LOG_CONVERSATION=1` to ship transcripts as well —
   read
   [Conversation logging (opt-in)](#conversation-logging-opt-in) first, since
   that ships what you and the model actually say.
   → [Network request logging](#network-request-logging),
   [Viewing logs in Grafana](#viewing-logs-in-grafana)

### GitHub push (opt-in)

Per launch, not a persistent setting:

```sh
ALLOW_GITHUB_PUSH=1 dejima ~/myproject
```

Pair it with a repo-scoped deploy key in `SANDBOX_SSH_KEY`. Read
[GitHub push: blocked by default, optional opt-in](#github-push-blocked-by-default-optional-opt-in)
before turning it on — with a forwarded personal agent this is much broader
than it looks.

### Remote access (opt-in)

Entirely off until step 1 exists. **Read
[docs/remote-access.md](docs/remote-access.md) end to end before doing any of
this.** Step 2 is the one that carries the security of the whole feature, and
getting it wrong still looks like it works.

1. **Create `~/.config/dejima/remote.conf`.** This file is the switch —
   nothing here runs without it. Set `NTFY_URL`, `BASE_URL`, and `TTYD_PORT`
   if you want something other than 7681. →
   [`remote.conf`](docs/remote-access.md#remoteconf)
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
5. **If you will read it on a phone**, take the `sub_filter` viewport line
   from the example config too. `ttyd` ships no viewport meta, so without it
   the mobile view is unreadably small and will not reflow. →
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
`gitea-merge-guard.sh` below. `gitea-issue` is on `PATH` too, for the work
that gets deferred rather than done: `list`, `view`, `create`, `comment`,
`close` and `reopen`, so a problem found mid-session becomes a ticket instead
of a footnote on an unrelated PR.

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
SANDBOX_CMD=nvim dejima ~/repos/some-project
```

Runs unconfigured unless you also set `SANDBOX_NVIM_CONFIG` to a real config
directory on the host (bind-mounted read-only at `~/.config/nvim` — lazy.nvim's
lockfile is the one exception, layered read-write on top so plugin syncs
don't fail on a read-only filesystem; nothing else in the config is
writable):

```sh
SANDBOX_CMD=nvim SANDBOX_NVIM_CONFIG=~/.config/nvim dejima ~/repos/some-project
```

Set both in your shell profile if you use this mode regularly.

If your config references something outside that directory by absolute host
path (a helper script in a dotfiles `bin/`, say), bring it in with
`SANDBOX_EXTRA_MOUNTS` (colon-separated, mounted read-only at the same path):

```sh
SANDBOX_EXTRA_MOUNTS=~/dotfiles/bin dejima ~/repos/some-project
```

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
push access, then:

```sh
SANDBOX_SSH_KEY=~/.ssh/dejima_ed25519 dejima ~/repos/some-project
```

`entrypoint.sh` loads it into a container-local `ssh-agent` at startup and
deletes the plaintext copy immediately after — the sandbox user itself never
has a path to the raw key, only the agent socket (see
[security notes](docs/security.md) for the full mount rationale). Setting
`SANDBOX_SSH_KEY` means a live forwarded agent is no longer required at all.

## Shared scratch space

`~/shared` is a read-write bind mount of `$SANDBOX_SHARE_DIR` (default
`~/.local/share/dejima/shared`, created automatically) — separate
from the project mount, for passing files (screenshots, temp scripts) in and
out of a session without touching the actual checkout. Persists across
sessions since it's a real directory, not a container volume.

It's also the answer if your own `CLAUDE.md` tells agents to put something at
a fixed host path — design docs, scratch notes, anything meant to outlive the
session but stay out of the project checkout. Point that convention at
`~/shared` (or set `SANDBOX_SHARE_DIR` to wherever you keep it) rather than
expecting some other host directory to be present in the container: this is
the only writable host path mounted besides the project itself.

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
`ALLOW_GITHUB_PUSH=1` is set. For a real guarantee against pushes to
main/master, use branch protection on the remote itself.

`gitea-merge-guard.sh` (`PreToolUse`/`Bash`, `DEJIMA`-gated) blocks
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
- `registry.npmjs.org`, `pypi.org`, `files.pythonhosted.org` (npm and
  mason's Python-based LSP tools), `release-assets.githubusercontent.com`
  (GitHub release assets, a separate CDN from github.com's own IPs),
  `proxy.golang.org`, `sum.golang.org` (`go` module proxy/checksums);
  `api.anthropic.com` when the credential proxy is off (kill switch or API-key auth)
- whatever `GITEA_SSH_HOST`/`GITEA_API` resolve to — not port-restricted, so
  git-over-ssh to Gitea works without a blanket "port 22 to anywhere" rule

Everything else is rejected. Run `dejima-allow <domain> --global`
(or `--project <path>` for one project) to allow more permanently (e.g.
`crates.io` for a Rust project), or `ENABLE_FIREWALL=0` to disable the
firewall entirely (debugging only).

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
dejima-allow crates.io                # this session only
dejima-allow crates.io --global       # + persist for every project
```

It first adds the domain to the running dnsmasq's allowlist (appends a
`server=` line to its servers-file and sends `SIGHUP` to reload just that
file - no restart), then resolves it through the now-unblocked container
resolver and adds the IP(s) to the running firewall's `ipset`, all via
`docker exec -u root`. It finishes by checking the domain is actually
reachable from inside that same container and prints a definitive verdict
— exit code 2 if it isn't. That check is a report on the live session only,
not a gate on approval: `--global`/`--project` persistence is recorded
first and unconditionally, since the domain being approved may legitimately
not answer on 443 (an internal service, an SSH-only host) and the natural
moment to add a global approval is precisely when nothing is running to
probe in the first place. (`--project` persistence likewise does not need a
running container at all — see below.) `--global` writes the domain to the
global approval store for every future session; `--global` and `--project`
are not mutually exclusive here - give both together and each persists to
its own store. If more than one dejima container is running, pass
`--container <name>` to disambiguate - `docker ps` finds it, or use the
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
named before the container starts (`GITEA_SSH_HOST`, `GITEA_API`,
`LOKI_URL`, and any globally or per-project approved domain) are already
exempted and unaffected by this.

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
.dejima/dependencies       # <apt|npm|pip|cargo>:<name> per line
```

**Declaring grants nothing.** The project directory is bind-mounted
read-write, so a compromised session could write these files - they are only
ever read to compare against reality and suggest a command. Approvals live
outside the container, under `~/.config/dejima/` by default
(`$DEJIMA_CONFIG_DIR` relocates the whole tree) - global at its
root, per project under `projects/<slug>/` - and are written only by tools
you run on the host:

```sh
dejima-project status ~/myproject     # declared vs approved vs missing
dejima-project approve ~/myproject    # review and approve the declared set
dejima-allow crates.io --project ~/myproject
dejima-allow crates.io --global       # applies to every project
dejima-dep add cargo:cargo-nextest --project ~/myproject
dejima-dep add cargo:cargo-nextest --global
```

`dejima-project status`/`approve` classify a declared entry against
the union of global and project approvals, so something already approved
globally shows as approved, not pending. Unlike `dejima-allow`,
`dejima-dep`'s `--global` and `--project` are mutually exclusive -
an entry belongs to exactly one scope.

Approved domains join the allowlist at the next launch (or immediately, for
`dejima-allow`, which also updates the running session). Approved
dependencies are baked into a derived image built `FROM` the shared base -
first `dejima:<username>-global`, if the global store has any
dependency approved, then `dejima:<username>-<slug>` on top of that,
if the project store does - so they need an image rebuild: they take effect
on the **next** launch.

Because of that rebuild, the usual moment to approve is *after* leaving the
sandbox — so persistence (`--global` or `--project`) never requires a running
container, and is never gated on the reachability probe `dejima-allow`
runs against a live session. Recording the approval is your decision;
patching a live session and verifying the domain answers on 443 are
best-effort on top of it, and `dejima-project approve` reports at the
end which domains it could not apply to a running session rather than
stopping at the first one.

A session whose project declares something it doesn't have is told so in its
startup context, with the exact command to hand you. Project approvals are
inherited by subdirectories, so a git worktree under the project gets its
parent's; global approvals apply everywhere regardless.

## Network request logging

If `LOKI_URL` is set (see Prerequisites), every DNS query and every new
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

Set `SANDBOX_LOG_CONVERSATION=1` (with `LOKI_URL` configured) to also ship
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
source pointed at wherever `LOKI_URL` resolves to (Connections → Data
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

The sandbox can always read from GitHub (clone, fetch, `gh` API calls). By
**default** it can never push there — enforced at the network layer, not
just by `git-push-guard.sh`: GitHub's IP ranges are only allowlisted on port
443. Port 22 is unreachable, so SSH-based push has no transport at all,
regardless of what any hook does or doesn't catch.

**Opt-in, not hardcoded** — set `ALLOW_GITHUB_PUSH=1` to open port 22 to
GitHub and let `git-push-guard.sh` accept `github.com`/`ssh.github.com` as a
push destination (the no-direct-to-main rule still applies):

```sh
ALLOW_GITHUB_PUSH=1 dejima ~/repos/some-project
```

**Read this before turning it on.** Whether a push actually succeeds depends
entirely on what SSH key is loaded into the agent. A forwarded personal
agent with your normal GitHub key would let a compromised session push to
**any** repo that key can write to, not just the one you intended — agent
forwarding doesn't distinguish push from pull. Use a dedicated,
**repo-scoped GitHub deploy key** via `SANDBOX_SSH_KEY` instead whenever
`ALLOW_GITHUB_PUSH=1` is set — that's what actually limits the blast radius.
`ALLOW_GITHUB_PUSH` only changes the firewall/hook's *host* check; it adds no
credential-loading path of its own.

`GH_TOKEN` must stay a **read-only** fine-grained PAT regardless of this
setting. `gh auth setup-git` (run at container start if `GH_TOKEN` is set)
points git's github.com HTTPS credential helper at `gh`, which only ever
holds whatever token `GH_TOKEN` provides — a write-scoped token there would
make HTTPS push possible independent of `ALLOW_GITHUB_PUSH`, so don't use
one.

`ALLOW_GITHUB_PUSH` is a per-launch variable, not a persistent toggle — it
only affects the one `dejima` invocation it's set for.

## Remote access

**Opt-in, and off entirely unless you create `~/.config/dejima/remote.conf`.**
Reach a running sandbox from another machine or a phone - over SSH or a
browser - and get a push when a session wants you. Two front doors and a
notification path, none of which exist until you configure them.

It is documented separately because getting the bind address wrong is the one
mistake here that exposes a `--dangerously-skip-permissions` shell to your
network, and that deserves more room than a section.

**→ [docs/remote-access.md](docs/remote-access.md)** - `remote.conf`, picking a
bind address and verifying it, the SSH and web front doors, reading and typing
on a phone, running behind another reverse proxy, notifications, and attaching.

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
bats test/static.bats test/project.bats test/remote.bats test/audit.bats  # fast, no Docker/build needed
SKIP_BUILD=1 bats test/runtime.bats   # reuse the current image
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
`remote.conf` parsing, the session registry, and the properties the
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
| `hooks/sandbox-context.sh` | `SessionStart` hook: injects sandbox context/workflow reminders |
| `hooks/git-push-guard.sh` | `PreToolUse` hook: blocks pushes outside the allowed host(s)/branches |
| `hooks/deny-dangerous-bash.sh` | `PreToolUse` hook: blocks obviously destructive Bash commands |
| `hooks/gitea-merge-guard.sh` | `PreToolUse` hook: blocks `gitea-pr merge` in the sandbox — merging is a human decision |
| `hooks/dejima-notify.sh` | `Notification`/`Stop` hook: drops an empty `waiting`/`done` marker for a remote-enabled session - see [docs/remote-access.md](docs/remote-access.md) |
| `bin/dejima-attach` | Lists live sessions and attaches to one; the shared core behind both remote front doors |
| `bin/dejima-audit` | Advisory exit-time diff of host-persistence surfaces (git config, `.claude/`, etc.) |
| `bin/dejima-dep` | Review and approve project dependencies declared in `.dejima/dependencies` |
| `bin/gitea-pr` | Create a PR, read its comments, merge it; baked into the image so the sandbox can open PRs |
| `bin/gitea-issue` | List, view, create, comment on, close and reopen Gitea issues; also baked into the image |
| `bin/dejima-notify-watch` | Host-side watcher: turns markers into ntfy pushes composed entirely from host data |
| `bin/dejima-project` | Review and approve project domains and dependencies from the host |
| `bin/dejima-project-lib.sh` | Shared library sourced by `bin/dejima-dep`, `bin/dejima-project`, `bin/dejima` and the remote-access scripts; not on PATH |
| `bin/dejima-ttyd` | Launches `ttyd` on loopback in front of `dejima-attach` |
| `systemd/*.service` | User units for `dejima-ttyd` and `dejima-notify-watch`; ship disabled, installed by hand |
| `docs/nginx-dejima.conf.example` | Reverse-proxy template for the web front door; deliberately not loadable as written |

`bin/dejima` is the entry point — it resolves the project path,
checks for a live `ssh-agent`, loads `GITEA_TOKEN`/`GH_TOKEN` if not already
set, discovers which host directories need mounting for symlinks under
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
