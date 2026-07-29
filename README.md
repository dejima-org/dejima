# dejima

Runs Claude Code inside a firewalled Docker container with
`--dangerously-skip-permissions` (no permission prompts, all tool use
auto-accepted), against a project bind-mounted from the host. Inspired by
[Anthropic's reference dev container](https://github.com/anthropics/claude-code/tree/main/.devcontainer),
reworked to run via `docker compose` directly and extended with a `gitea-pr`
helper for opening/iterating on PRs against Gitea or Forgejo, plus an
optional editor-driven workflow in place of bare Claude Code (see "Usage").

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

## Prerequisites

- Docker with the `docker compose` v2 plugin.
- `python3` (stdlib only — no packages) — runs the host-side credential proxy
  (see "Security notes").
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

That is enough to run `bin/dejima`.

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
ALLOW_GITHUB_PUSH=1 bin/dejima ~/myproject
```

Pair it with a repo-scoped deploy key in `SANDBOX_SSH_KEY`. Read
[GitHub push: blocked by default, optional opt-in](#github-push-blocked-by-default-optional-opt-in)
before turning it on — with a forwarded personal agent this is much broader
than it looks.

### Remote access (opt-in)

Entirely off until step 1 exists. **Read
[Remote access](#remote-access) end to end before doing any of this.** Step 2
is the one that carries the security of the whole feature, and getting it
wrong still looks like it works.

1. **Create `~/.config/dejima/remote.conf`.** This file is the switch —
   nothing here runs without it. Set `NTFY_URL`, `BASE_URL`, and `TTYD_PORT`
   if you want something other than 7681. →
   [`remote.conf`](#remoteconf)
2. **Choose the reverse proxy's bind address, on the dejima box itself.** One
   specific address on its LAN interface. Never the wildcard, never
   `0.0.0.0`, never a Docker bridge. →
   [The bind address is the one thing to get right](#the-bind-address-is-the-one-thing-to-get-right),
   [Picking the address](#picking-the-address)
3. **SSH front door.** Generate a key that exists only for this, then add one
   `restrict,pty,command="…/dejima-attach"` line to `authorized_keys` for the
   same Unix user that runs `bin/dejima`. →
   [SSH front door](#ssh-front-door)
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
   [Web front door](#web-front-door)
5. **If you will read it on a phone**, take the `sub_filter` viewport line
   from the example config too. `ttyd` ships no viewport meta, so without it
   the mobile view is unreadably small and will not reflow. →
   [Reading it on a phone](#reading-it-on-a-phone)
6. **If another reverse proxy sits in front of this one**, it needs SNI, a
   single literal `Host`, the upgrade headers and its own long read timeout —
   and it changes the threat model. →
   [Behind another reverse proxy](#behind-another-reverse-proxy)
7. **Notifications.** Install `systemd/dejima-notify-watch.service` the same
   way, then `loginctl enable-linger "$USER"` so both units survive logout. →
   [Notifications](#notifications)
8. **Verify the containment from inside a running sandbox** before relying on
   any of it. →
   [Verifying it](#verifying-it)

[Attaching](#attaching) then covers what you get on the other end.

## Usage

```sh
bin/dejima                        # sandbox the current directory
bin/dejima ~/repos/some-project
```

By default the container's entry point is bare `claude` (always running with
`--dangerously-skip-permissions`, regardless of how it's invoked — see
`docker/claude-wrapper.sh`), so a fresh clone of this repo works with no
editor setup at all.

Typical loop: point it at a project, ask Claude to implement something and
open a PR (`gitea-pr` is on `PATH`); from the host, `gitea-pr comments <PR#>`
to pull review feedback, feed it back in, repeat.

### Using a different editor/application

```sh
SANDBOX_CMD=nvim bin/dejima ~/repos/some-project
```

Runs unconfigured unless you also set `SANDBOX_NVIM_CONFIG` to a real config
directory on the host (bind-mounted read-only at `~/.config/nvim` — lazy.nvim's
lockfile is the one exception, layered read-write on top so plugin syncs
don't fail on a read-only filesystem; nothing else in the config is
writable):

```sh
SANDBOX_CMD=nvim SANDBOX_NVIM_CONFIG=~/.config/nvim bin/dejima ~/repos/some-project
```

Set both in your shell profile if you use this mode regularly.

If your config references something outside that directory by absolute host
path (a helper script in a dotfiles `bin/`, say), bring it in with
`SANDBOX_EXTRA_MOUNTS` (colon-separated, mounted read-only at the same path):

```sh
SANDBOX_EXTRA_MOUNTS=~/dotfiles/bin bin/dejima ~/repos/some-project
```

## Config parity with your host Claude Code setup

`~/.claude` is bind-mounted read-write, so global `CLAUDE.md`, settings,
hooks, and plugins all carry over automatically, and your existing login
stays effective too — no separate first-run login, though the credential
itself doesn't enter the container directly (see "Security notes" for the
host-side proxy that makes that work). (`~/.claude.json` is handled
differently — a throwaway per-session copy, not the real file; see "Security
notes" below for exactly what that means.)

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
`bin/dejima`. Images are tagged per-user (`dejima:<username>`)
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
SANDBOX_SSH_KEY=~/.ssh/dejima_ed25519 bin/dejima ~/repos/some-project
```

`entrypoint.sh` loads it into a container-local `ssh-agent` at startup and
deletes the plaintext copy immediately after — the sandbox user itself never
has a path to the raw key, only the agent socket (see "Security notes" for
the full mount rationale). Setting `SANDBOX_SSH_KEY` means a live forwarded
agent is no longer required at all.

## Shared scratch space

`~/shared` is a read-write bind mount of `$SANDBOX_SHARE_DIR` (default
`~/.local/share/dejima/shared`, created automatically) — separate
from the project mount, for passing files (screenshots, temp scripts) in and
out of a session without touching the actual checkout. Persists across
sessions since it's a real directory, not a container volume.

`~/specs` is also bind-mounted read-write at the fixed host path `~/specs`
(not configurable) — makes the global `CLAUDE.md` convention of writing specs
there actually persist, instead of vanishing with the container.

## Testing frontend changes

Playwright (Chromium) is pre-installed at image build time, browser
included — `require("playwright")` works from any script, no network access
or per-project `npm install playwright` needed.

`localhost`/loopback traffic never goes through the egress firewall, so a
project's own dev server needs no firewall changes. A real external site
needs to be on the allowlist like any other network use
(`bin/dejima-allow <domain>` for a running session, add
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
(`PreToolUse`) also applies here, since `~/.claude` is shared.

`git-push-guard.sh` (`PreToolUse`/`Bash`, also `DEJIMA`-gated) blocks
any `git push` whose resolved remote isn't the Gitea host, and any push to
`main`/`master` even there. Like the other hooks, this is a fast-fail guard
against an overeager agent, not a hard security boundary — a session has full
shell access and could in principle edit `.git/config` to route around it.
GitHub push is blocked by default too (see "GitHub push" below) unless
`ALLOW_GITHUB_PUSH=1` is set. For a real guarantee against pushes to
main/master, use branch protection on the remote itself.

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
  `proxy.golang.org`, `sum.golang.org` (`go` module proxy/checksums),
  `api.anthropic.com`
- whatever `GITEA_SSH_HOST`/`GITEA_API` resolve to — not port-restricted, so
  git-over-ssh to Gitea works without a blanket "port 22 to anywhere" rule

Everything else is rejected. Run `bin/dejima-allow <domain> --global`
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
bin/dejima-allow crates.io                # this session only
bin/dejima-allow crates.io --global       # + persist for every project
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
ALLOW_GITHUB_PUSH=1 bin/dejima ~/repos/some-project
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
only affects the one `bin/dejima` invocation it's set for.

## Remote access

**Opt-in, and entirely off until you create one file.** Nothing here runs and
no front door exists unless `~/.config/dejima/remote.conf` is present. With
it absent, `bin/dejima` builds exactly the `docker compose` invocation it
built before this feature existed, no session state is written, no
notification hook is registered, and `dejima-attach`, `dejima-ttyd` and
`dejima-notify-watch` each refuse to run at all. `install.sh` symlinks those
three onto `PATH` and stops there - it runs no `systemctl`, copies no unit,
and starts nothing.

What this is: a way to get back to a session that is *already running* on
your machine, from a phone on the same network, when it stops to ask you
something. What it is not: a way to start a session, a hosted service, or
anything that should face the internet.

**Both front doors hand out a host shell.** `dejima-attach` attaches a tmux
client on your own tmux server, and a tmux client is one prefix key away
from a new window that has nothing to do with any sandbox. Everything below
follows from that single fact - it is why the listener is on loopback, why
the proxy needs authentication, and why the bind address is the one step to
get right.

### `remote.conf`

Flat `KEY=value` lines, `#` comments and blank lines ignored, at
`~/.config/dejima/remote.conf` (`$DEJIMA_CONFIG_DIR` relocates the whole
config tree, same as it does for approvals):

| Key | Default | Purpose |
| --- | --- | --- |
| `NTFY_URL` | unset | ntfy topic to push notifications to. `dejima-notify-watch` refuses to start without it; nothing else reads it |
| `BASE_URL` | unset | public base URL of the web front door, used to build the notification's deep link. Absent, pushes still go out - just with no link on them |
| `TTYD_PORT` | `7681` | loopback port `ttyd` listens on. The reverse proxy has to `proxy_pass` to the same one |
| `TTYD_FONT_SIZE` | unset | terminal font size in px, 8-72. Applies to *every* client, phone and desktop alike - see "Reading it on a phone". Unset passes no option at all and leaves `ttyd` on its own default |

`NTFY_URL` and `BASE_URL` must carry an explicit `http://` or `https://`
scheme; a value without one is refused rather than guessed at, because
`curl` reads a leading `-K/path` as an *option* that takes the request's URL
from that file instead. Values are restricted to
`A-Za-z0-9:/._~?=%@+-` — no whitespace and nothing shell-active, since these
end up in an HTTP header and in a URL handed to a phone.

**A malformed file is a hard failure, not a warning.** The whole file is
validated on every read, not just the key being asked for: an unknown key, a
value outside that character set, or a line without an `=` makes
`dejima-ttyd` and `dejima-notify-watch` refuse to start and say which line
was wrong. A `TTYD_PORT` that isn't a number in 1-65535 is refused the same
way, as is a `TTYD_FONT_SIZE` outside 8-72 - a size big enough to make one
glyph wider than the viewport renders a terminal that shows nothing, which
reads as a broken front door rather than as a typo three files away.

Those are the two scripts that read a *value* out of the file.
`dejima-attach` and `bin/dejima` do not - to them the file is a switch, and
all they ask is whether it exists - so neither one parses it and neither
refuses on a bad line. That is deliberate rather than an oversight: a
malformed line cannot change what they do, and making the front door refuse
to open over a typo would take away the terminal you would fix it from.

```
# ~/.config/dejima/remote.conf - substitute your own topic and hostname
NTFY_URL=https://ntfy.example.invalid/your-topic-here
BASE_URL=https://dejima.example.invalid
TTYD_PORT=7681
# TTYD_FONT_SIZE=20   # optional, and applies to the desktop too
```

**Editing this file changes nothing until the services restart.** Every value
is read once, at process start - `dejima-ttyd` reads `TTYD_PORT` and
`TTYD_FONT_SIZE` and then `exec`s `ttyd` with them baked into its argv. So:

```sh
systemctl --user restart dejima-ttyd.service
systemctl --user restart dejima-notify-watch.service   # if NTFY_URL changed
pgrep -a ttyd    # confirm the argv is what you just configured
```

Skipping this is quiet rather than loud: nothing warns, and the front door
keeps serving with the old settings, which reads as "the setting had no
effect" rather than as "the process is older than the file".

### The bind address is the one thing to get right

This is the step that carries the whole feature's security, and the only one
where a plausible-looking choice is a full sandbox escape.

`docker/init-firewall.sh` deliberately ACCEPTs container OUTPUT to the
container's default-route address - the Docker bridge gateway, which is your
host. That is the one host address a sandbox can reach at all. Combine it
with the fact above (a tmux client is a host shell) and the consequence is
direct: **a front door the sandbox can reach is a compromised session's own
escape hatch.**

So:

- `ttyd` is bound to `127.0.0.1` by `bin/dejima-ttyd`, hardcoded, not
  configurable. The container has no route to your host's loopback, so
  nothing but a process on this host can open that socket.
- **The reverse proxy has to run on that same host** - the dejima box, the
  one your sandboxes start on. That is not a preference, it is what the
  loopback bind implies: `proxy_pass http://127.0.0.1:<TTYD_PORT>` only
  resolves to `ttyd` from the same machine. If you already run a proxy on a
  *different* box, do not point it here - reaching `ttyd` from there would
  mean binding `ttyd` to a routable address, which is precisely the escape
  this whole section exists to prevent. Put a second, small proxy on the
  dejima box instead.
- That proxy must bind **one specific address, on the dejima box's LAN
  interface**. Never the wildcard - a bare `listen 443 ssl;` is every
  interface *including* the Docker bridges - never `0.0.0.0`, and never a
  bridge address.

### Picking the address

`ip -br addr` on the dejima box lists more candidates than you want, because
Docker adds its own. It looks something like this:

```
lo               UNKNOWN  127.0.0.1/8 ::1/128
enp3s0           UP       192.0.2.24/24 <a link-local v6 address>
docker0          UP       <docker's own subnet>
br-9f3c1a2b4d5e  UP       <docker's own subnet>
```

Only the physical LAN interface qualifies - `enp3s0` here; yours may be
`eth0`, `wlan0`, `enp0s31f6`, or a bond. So `listen 192.0.2.24:443 ssl;`,
using your own address in place of that one.

Everything else on that list is disqualified, and two of them dangerously
so. `lo` is where `ttyd` already is. `docker0` and every `br-<hash>` are
Docker bridges - **these are the addresses a sandbox can reach**, so a proxy
bound to one is a front door opening inward. If you are unsure which lines
those are, ask for exactly them:

```sh
ip -br addr show type bridge   # every address here is disqualified
```

Cross-check from the other side, too: the address a running sandbox has a
route to is the one to avoid, and the container will tell you which it is -
`docker exec <container> ip route | grep default` names it.

Afterwards, `ss -ltnp | grep <TTYD_PORT>` should show `ttyd` on `127.0.0.1`
only, and `ss -ltnp` on your proxy's port should show the single LAN address
you chose - not `*` and not `0.0.0.0`.

### Verifying it

Verify rather than assume. With a sandbox running, from inside it (adjust
`7681` if you changed `TTYD_PORT`, and `443` to whatever port your proxy
listens on):

```sh
# the bridge gateway - the only host address this container can route to
gw=$(ip route | grep default | cut -d' ' -f3)

# both should fail: the loopback ttyd, and the front door's own port
timeout 5 bash -c "cat < /dev/null > /dev/tcp/$gw/7681" && echo BAD || echo ok
timeout 5 bash -c "cat < /dev/null > /dev/tcp/$gw/443"  && echo BAD || echo ok
```

`BAD` on either line means stop and fix the bind before going further -
whatever answered is reachable from inside the sandbox. The first line is
also what catches a distro `ttyd.service` still running on that port, which
is why this is worth doing even if you are confident about the proxy. `test/runtime.bats`
asserts this same containment property against a live container (with a
positive control on the same path, so a passing result can't come from the
container simply reaching nothing), and it passes on a real Docker host.

### SSH front door

Generate a key that exists only for this, and give it a forced command:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/dejima-phone -C phone
```

Then one line in `~/.ssh/authorized_keys`, with the full path to the symlink
`install.sh` made:

```
restrict,pty,command="/home/<you>/.local/bin/dejima-attach" ssh-ed25519 AAAA... phone
```

`restrict` turns off port forwarding, agent forwarding, X11 and everything
else; `pty` adds back the one thing a terminal needs; `command=` runs
`dejima-attach` no matter what the client asks to run. Nothing the phone
sends is interpreted as a command, so this needs no client-side
"run this on connect" support - any plain SSH app lands on the picker.

It has to be the **same Unix user** that runs `bin/dejima`: tmux sockets are
per-user, and `dejima-attach` talks to the tmux server of whoever runs it.
Options are per-key, so your normal key still gets a normal shell - worth
confirming both after you add the line.

### Web front door

Needs `ttyd` **1.7.4 or newer**. `-W`/`--writable` arrived in 1.7.4, which
inverted the old default (before it, the terminal was writable unless you
passed `--readonly`), so an older build rejects the flag and
`bin/dejima-ttyd` fails at every start. Your distro's package may well be
too old: Debian bookworm's is 1.7.3 and Ubuntu 22.04's is 1.6.3, neither of
which has the flag - Ubuntu 24.04's 1.7.4 does. Check with `ttyd --version`,
and take an upstream release binary if the packaged one is behind.

On Debian there is a middle option: sid packages **1.7.7**, and you can take
that one package without moving the rest of the system to unstable. sid is
not a configured source on a stable install, so add it - and pin it *below*
your normal release, or the next `apt upgrade` follows it:

```sh
echo 'deb http://deb.debian.org/debian unstable main' \
    | sudo tee /etc/apt/sources.list.d/sid.list

# without this pin the whole system drifts to unstable
printf 'Package: *\nPin: release a=unstable\nPin-Priority: 10\n' \
    | sudo tee /etc/apt/preferences.d/99-sid

sudo apt update
sudo apt install -t unstable ttyd    # -t overrides the pin, for this package
```

Read what `apt` proposes before agreeing to it. One package from sid drags
its libraries along, and if the plan includes `libc6` you are no longer
taking one package - back out and use an upstream release binary instead.
`apt_preferences(5)` has the details.

**Installing the package opens a door of its own. Close it.** However you get
`ttyd` from a distro repository - stable, sid, Ubuntu - the package ships a
*system* service that systemd enables and starts on install. It serves a
login prompt, and because it passes no `--interface` of its own it binds
**every** interface, the bridge address a sandbox routes to included. It
listens on `ttyd`'s default port, which is the port this feature defaults to
as well.

Two consequences, and the second is the one that hides:

- A host login prompt is now reachable *from inside every container you run*,
  put there by the act of installing the package.
- It holds the port, so `dejima-ttyd` fails to bind at every start while your
  reverse proxy proxies to the distro's `ttyd` instead. You get your own
  password prompt and then a host login shell, on the hostname you set up for
  dejima, with nothing along the way appearing broken.

```sh
systemctl status ttyd.service              # almost certainly active
sudo systemctl disable --now ttyd.service
sudo systemctl mask ttyd.service           # so reinstalling cannot revive it
```

`bin/dejima-ttyd` refuses to start when anything already holds its port and
names this as the likely cause, rather than leaving you with `ttyd`'s
one-line bind error in a unit nobody is watching. That is a diagnostic, not a
fix: the listener is there from the moment the package lands, whether or not
you ever run `dejima-ttyd`.

`bin/dejima-ttyd` reads `TTYD_PORT` and launches
`ttyd --interface 127.0.0.1 --port <port> --check-origin --url-arg --writable dejima-attach`.
Two of those are load-bearing:

- **`--check-origin`** is not tidiness. Without it `ttyd` does no origin
  validation at all, and browsers do not apply the same-origin policy to
  WebSockets - they do attach the cached credential for the target origin.
  Any page loaded in an authenticated operator's browser could open
  `wss://<front-door>/ws` and be handed this host shell, with no interaction
  beyond visiting the page. Proxy authentication cannot stop that; it is
  satisfied by the victim's own browser.
- **`--url-arg`** is what lets the notification's deep link name a session
  (`?arg=<run-id>`). It reaches `dejima-attach` as argv, never as a shell
  word, and has to match the run-id shape before it is used for anything.

Install the unit by hand - it ships disabled, and `install.sh` will not do
this for you:

```sh
mkdir -p ~/.config/systemd/user
cp systemd/dejima-ttyd.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now dejima-ttyd.service
```

It is a **user** unit, not a system one, and it repeats no configuration:
`ExecStart` is `%h/.local/bin/dejima-ttyd`, and the bind address and port
live in the script and `remote.conf` so the two cannot drift.

Then put a reverse proxy in front of it. Adapt
`docs/nginx-dejima.conf.example` - it will not load as written, deliberately,
so it can never become a live config by being dropped into `sites-enabled`
and forgotten. What matters in it:

- **Authentication on every server block.** `ttyd` is started with no
  credential of its own, because the loopback bind means only this host can
  reach it - the proxy is the entire gate. A block without `auth_basic` is
  an unauthenticated host shell on your network.
- **A `default_server` that refuses.** nginx picks a server block by
  SNI/`Host`, and when nothing matches it serves the **default** for that
  listen address - which, if the front door is the only block on it, is the
  front door. `server_name` on its own therefore isolates nothing: the vhost
  answers to *every* name that resolves to that address, including the box's
  own hostname. The example ships a first block that is `default_server` and
  does nothing but `ssl_reject_handshake on;`, so only the name you chose
  gets through. If you already have a default server on that address, keep
  the one you have - just make sure it doesn't fall through to this vhost.
- **TLS.** HTTP Basic sends the password on every request, and the terminal
  itself carries whatever the session is working on.
- **`proxy_set_header Host $http_host;`** — `$http_host`, not `$host`.
  `--check-origin` compares the client's `Origin` against the `Host` header,
  and nginx's `$host` has the port stripped while `ttyd` keeps the port in
  what it compares unless it is 80 or 443. On a vhost listening anywhere
  else - 8443, say - `$host` makes `ttyd` compare `name:8443` against `name`
  and refuse every WebSocket: the page loads, the terminal never connects,
  and the only sign is a "refuse to serve WS client from different origin"
  line in `ttyd`'s log.
- **A long `proxy_read_timeout`.** An attached terminal sits idle for hours;
  nginx's default is 60 seconds.

### Reading it on a phone

Out of the box the phone view is close to unusable: text renders far too
small to read, and pinch-zooming leaves you panning around a giant canvas
instead of reflowing anything. That is not a font setting you missed.

**`ttyd` serves no viewport meta tag** - not in 1.7.7, not on `main` at the
time of writing. A mobile browser that finds no `<meta name="viewport">`
assumes the page was written for a desktop, lays it out at a virtual width
of around 980 CSS pixels, and scales the result down to fit the screen.
Everything shrinks together, so raising the font size just gives you a
larger font scaled down by the same factor. And a terminal is a fixed
character grid on a canvas: zooming magnifies pixels, it does not re-wrap
lines the way zooming a text page does.

The fix is to supply the tag the page is missing, which the proxy can do on
the way past. `docs/nginx-dejima.conf.example` ships it:

```nginx
sub_filter '<head>' '<head><meta name="viewport" content="width=device-width, initial-scale=1">';
sub_filter_once on;
proxy_set_header Accept-Encoding "";
```

Now the browser lays out at the device's real width, xterm.js fits an honest
column count to it, and rotating the phone reflows properly. Desktop
browsers ignore `width=device-width`, so nothing changes there.

Two things that will waste your time if you skip them:

- Your nginx needs the sub module, and a missing one fails *quietly*. Check
  for it up front, and validate with **`nginx -t`** rather than trusting the
  reload - a reload whose config does not parse leaves the *old* config
  running while `systemctl reload nginx` still reports success, so an unknown
  `sub_filter` directive looks from the outside exactly like a directive that
  ran and did nothing.

  ```sh
  /usr/sbin/nginx -V 2>&1 | tr ' ' '\n' | grep http_sub_module
  sudo /usr/sbin/nginx -t
  ```

  The path is spelled out because Debian and Ubuntu install nginx to
  `/usr/sbin`, which is on root's `PATH` and not on yours - a bare `nginx -V`
  answers `command not found` on a box that is running nginx perfectly well.
  Debian's `nginx-light` is built without the module; `nginx-core`,
  `nginx-full` and `nginx-extras` have it.
- `sub_filter` cannot rewrite a compressed response body and passes it
  through untouched, which looks exactly like the tag not working. Clearing
  `Accept-Encoding` toward the upstream is what stops that.

If the text is still smaller than you want once the layout is honest, set
`TTYD_FONT_SIZE` in `remote.conf` (8-72). Be aware of what it costs:
**it applies to every client.** `ttyd` 1.7.7 accepts client options only at
launch - the URL-query override that would let a deep link carry its own
size landed upstream after 1.7.7 was cut - so there is no way from here to
give a phone one size and the desktop another. A larger size also means
fewer columns, and because attaching shares the window with your desktop
session, tmux resizes that window to whichever client used it last. Start by
fixing the viewport and only reach for this if you still need it.

### Behind another reverse proxy

Terminating TLS somewhere else and forwarding here is a supported shape, but
read this first: it moves the front door out of the LAN threat model
everything above is written against. If the outer proxy is internet-facing,
`auth_basic` over TLS is now the only thing between the public internet and
a host shell. Put something stronger in front of it, and take the
"Security notes" section as the floor rather than the ceiling.

The mechanical part has four requirements at the outer hop, and each one
fails differently:

```nginx
proxy_ssl_server_name on;                    # else: TLS handshake refused
proxy_ssl_name  dejima.example.invalid;
proxy_set_header Host dejima.example.invalid;   # exactly once - see below
proxy_http_version 1.1;                      # else: page loads, terminal never connects
proxy_set_header Upgrade    $http_upgrade;
proxy_set_header Connection "upgrade";
proxy_read_timeout 1d;                       # else: dropped after 60s idle
```

- **`proxy_ssl_server_name` is off by default**, so nginx proxying to an
  HTTPS upstream sends no SNI at all. The inner nginx sees a handshake with
  no name, hands it to the `default_server` - which exists precisely to
  refuse unrecognised names - and you get a 502 at the outer hop.
- **Set `Host` exactly once.** `proxy_set_header` is additive within a
  configuration level rather than overriding, so declaring `Host` twice
  sends *two* `Host` headers and the inner nginx answers 400 to all of it.
  The easy way to do this by accident is `include proxy_params;` (Debian
  ships one that already sets `Host $http_host`) plus your own `Host` line
  in the same block.
- **A literal, not `$host` or `$http_host`.** The value has to be the
  hostname the *browser* used, because that is what `ttyd`'s
  `--check-origin` compares the `Origin` against at the far end. A literal
  also guarantees it agrees with `proxy_ssl_name`.
- **`Upgrade`/`Connection` and the timeout are needed at every hop**, not
  just the inner one. Miss them outside and the page loads while the
  terminal never connects - the same symptom the inner config produces, from
  a different place.

nginx logs the *reason* for a 400 at `info` level, which is below the
default. When something here is wrong and the access log only says `400`,
set `error_log /var/log/nginx/error.log info;` on the inner proxy, reproduce
once, and it names the cause outright. Turn it back down afterwards. To
establish which hop is at fault, bypass the outer one from the dejima box
itself:

```sh
curl -vk --resolve dejima.example.invalid:443:<dejima-box-lan-ip> \
    https://dejima.example.invalid/
```

A `401` there means the inner config is correct and the fault is entirely in
what the outer proxy sends.

### Notifications

`bin/dejima` registers `hooks/dejima-notify.sh` as a `Notification` and
`Stop` hook for a remote-enabled session - into the throwaway settings copy
it already generates for that session, never into your real
`~/.claude/settings.json`, which every sandbox's copy derives from and your
host's own Claude Code reads directly. That copy is mounted read-only, so a
session cannot unregister its own hook. The hook writes one empty file, named `waiting` or
`done`, into this run's own bind-mounted marker directory. No content, no
stdin, no network.

On the host, `dejima-notify-watch` turns those markers into ntfy pushes.
Same installation shape as above:

```sh
cp systemd/dejima-notify-watch.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now dejima-notify-watch.service
```

`inotify-tools` is optional - without `inotifywait` the watcher degrades to
a roughly six-second poll rather than failing (a one-second floor under the
loop plus a five-second sleep). Repeat markers for the same session and
event inside 60 seconds are debounced (`DEJIMA_DEBOUNCE_SECONDS` overrides
that).

One environment gotcha, because it fails silently: the watcher and
`bin/dejima` both resolve the marker root as `${XDG_RUNTIME_DIR:-/tmp}/dejima`,
so they only meet when they agree on `XDG_RUNTIME_DIR`. systemd sets it for
user units and a login shell gets it from pam_systemd, but a `bin/dejima`
run from a context that has neither - a bare `su`, a cron job, a tmux server
started before login - writes its markers under `/tmp/dejima` while the unit
watches `/run/user/<uid>/dejima`, and no push is ever sent, with nothing
logged to say so. `systemctl --user show-environment` is where to check.

The same directory is why you probably want lingering on:

```sh
loginctl enable-linger "$USER"
```

Both units here are *user* units. Without lingering they are stopped at
logout and `/run/user/<uid>` is destroyed with the session, taking the
session registry and every marker with it - so a sandbox left running in a
detached tmux session has no front door and sends no notification until you
log in again. It fails closed rather than open (nothing is left listening
unguarded), but it fails invisibly, and it is the same `XDG_RUNTIME_DIR`
that the gotcha above is about.

**The marker directory is a write channel into your runtime tmpfs**, and
nothing bounds it. `/run/user/<uid>` is RAM-backed and sized at a fraction
of physical memory, and each session gets its own directory under it
bind-mounted read-write, so a session that writes into `/run/dejima-notify`
until it is full degrades your whole login session - D-Bus, the systemd user
manager - and not just dejima. A session can already fill the workspace
mount, so this is an increment rather than a new kind of exposure, but a
RAM-backed filesystem fails harder and sooner than a disk. There is
deliberately no quota here; `rm -rf` on that run's marker directory (or
logging out, which discards the tmpfs) is the recovery.

**What a notification contains.** A title of `dejima: <project> needs input`
(or `dejima: <project> finished`), a fixed one-line body, and - when
`BASE_URL` is set - a click link of `<BASE_URL>/?arg=<run-id>` that opens the
web front door already attached to that session. `<project>` is the
workspace directory's name, taken from the host-side registry and reduced to
`A-Za-z0-9._-`.

**And nothing about what Claude is actually asking.** That absence is
deliberate, not a missing feature: your phone is outside the sandbox, so no
sandbox-controlled bytes are allowed to reach it. The question itself is on
the terminal you are about to attach to; the push exists only to tell you to
go look.

The guarantee for that is host-side, and it is worth being precise about
where it lives. The in-container hook's `waiting|done` whitelist is **not**
it - a compromised session owns its own bind-mounted marker directory and
can create any file name in it, hook or no hook. What holds is
`bin/dejima-notify-watch`: it iterates a literal two-name enum rather than
reading the directory, so a name outside it is never stat'd, read or
removed; it never reads marker *content*; and it consumes markers with
`rm -f`, which unlinks a symlink instead of following it. Every byte it
sends - title, body, headers, click URL - is composed from host data. That
last point is what the enum is really for: ntfy's own headers include
`X-Actions`, `X-Attach` and `X-Icon`, which can make the receiving phone
issue an arbitrary HTTP request, so a single attacker-controlled header
would turn it into a confused deputy inside your network.

**When no notification arrives.** Five things have to happen in order, and a
break in any of them looks identical from the phone - which is to say, like
nothing at all. Walk them from the inside out; each step tells you whether
the next one is worth checking.

1. **Is the session registered?** Inside the sandbox, `echo $DEJIMA_RUN_ID`
   and `echo $DEJIMA_NOTIFY_DIR`. Both empty means `bin/dejima` started this
   container with remote access off - `remote.conf` did not exist at launch,
   and no later change affects a session already running.
2. **Is the hook registered?** The `Notification` and `Stop` entries live in
   the throwaway settings copy, not in your real `settings.json`:
   `grep -c dejima-notify ~/.claude/settings.json` from inside should be 2.
3. **Does the marker reach the host?** This is the one worth knowing, because
   it splits the chain cleanly in half. From inside the sandbox:

   ```sh
   : > "$DEJIMA_NOTIFY_DIR/waiting" && sleep 2 && ls "$DEJIMA_NOTIFY_DIR"
   ```

   The file vanishing means the host watcher is running and consuming, and
   everything below this line is host-side. The file remaining means
   `dejima-notify-watch` is not running - `systemctl --user status
   dejima-notify-watch`, and check `enable-linger` if it died with your
   session.
4. **Did the push succeed?** `curl`'s stderr goes to the watcher's journal:
   `journalctl --user -u dejima-notify-watch -n 50`. A `push failed` line
   with a 404 usually means `NTFY_URL` names the server but no topic; a 401
   or 403 means the instance wants credentials, which the URL can carry as
   `https://<user>:<token>@<host>/<topic>` - nothing here sends an auth
   header of its own.
5. **Is the phone subscribed to the topic the config names?** Last in the
   list and first to check in practice, since it is the only link with no
   log anywhere. The topic in `NTFY_URL` and the one in the app have to be
   the same string.

Note also that step 3 sends a real notification when the chain is healthy,
which makes it a test of the whole path rather than only of the watcher.
Repeat runs within `DEJIMA_DEBOUNCE_SECONDS` (60 by default) are consumed
without pushing, so leave a minute between attempts or you will diagnose the
debounce instead.

### Attaching

`dejima-attach` with no argument gives a numbered picker - digits rather
than arrow keys, because a phone soft keyboard handles those far better.
`--list` prints one tab-separated row per live session for scripting, and a
run-id argument attaches directly, which is what the deep link and `ttyd`'s
`--url-arg` produce. Rows carry the run id, the tmux label, the workspace
name, the session's age, its state, and the container id.

Three states, from a registry `bin/dejima` writes on launch and removes on
exit:

- `attachable` - a live tmux pane to join.
- `stale` - registered, but its pane is gone. Listed rather than hidden,
  since the registry is a hint and not truth: the exit trap doesn't run
  under `SIGKILL` or a host crash.
- `no-tmux` - the sandbox was started outside tmux, so there is no pane to
  attach to. Still listed, deliberately, rather than silently omitted.

Entries whose container has gone away are pruned as they're listed. When
Docker can't be asked at all, nothing is pruned and the container column
reads `?` - an unanswerable question is never treated as a "no".

Attaching creates a **grouped** tmux session (`dejima-<run-id>`) rather than
joining yours. Grouped sessions share windows but track their own current
window, so the phone can sit on one sandbox while the desktop sits on
another, and the throwaway carries `destroy-unattached`, so it disposes of
itself when the phone detaches or the connection drops.

**You get the whole window list, not just the one sandbox.** Sharing windows
is what "grouped" means: you land on the right window, and every other
window on your tmux server is one tab away - other sandboxes, and whatever
non-dejima windows you have open. Worth knowing before you first connect,
because it is a surprise otherwise.

It is not a containment boundary being crossed, which is why it is left as
it is. Whoever reaches this terminal is one prefix key away from a brand new
host shell no matter what the tab bar shows - that is the fact this entire
feature is designed around, and tmux offers no per-client way to take the
prefix away (key tables are server-global, so disabling it for the phone
would disable it for your desktop too). Restricting the view would be
tidier; it would not make a reachable front door any less of a host shell.
Authentication and the bind address are the controls that matter here.

Sizing is left to tmux on purpose: `dejima-attach` sets no `window-size`.
tmux's own default (`latest`, since 3.1) already keeps a small phone client
from shrinking the desktop's view, and the option's only scopes are the
window - which a grouped session *shares* with yours, so setting it there
would permanently overwrite your choice with nothing to restore afterwards -
and global. An operator who deliberately set `smallest` keeps it.

## Security notes

**Threat model, honestly stated:** this reduces the blast radius of a
misbehaving or prompt-injected coding agent - it does not make it safe to
point at arbitrary untrusted or adversarial input, and it does not turn
`--dangerously-skip-permissions` into something without real risk. Point it
at repositories you already trust. Everything below is about how bad a
compromised session *inside* that trust boundary can get, not a claim that
one can't happen.

- `--dangerously-skip-permissions` removes your chance to review tool calls
  before they run. Only point this at trusted repositories.
- The mounted project itself has **no write protection**. `deny-dangerous-
  bash.sh` and `git-push-guard.sh` are regex pattern-matching on the literal
  Bash command string - a fast-fail guard against an overeager agent doing
  something obviously destructive, not a boundary against one that's
  actively trying to get around them (a different scripting language, an
  encoded command, editing `.git/config` directly all sail right through).
  Nothing here stops a compromised or badly-instructed session from
  modifying or deleting the real working copy it's mounted against.
- That same read-write access to the mounted project is also a
  host-code-execution vector, not just a data-destruction one: a
  compromised session could plant `.git/hooks/post-commit` (or
  `pre-push`), set `core.hooksPath`, or write a
  `.claude/settings.local.json` with a malicious hook command, into the
  project. Any of those run unsandboxed on the host the next time you run
  `git` or open Claude Code in that repo - no network egress required, so
  the firewall doesn't see it either. Same underlying persistence pattern
  as the `~/.claude/hooks` and `~/.claude.json` risks above, just through
  the project mount instead of the config mount. "Only point this at
  trusted repositories" (above) covers input trust; this is about the
  sandbox writing a persistence payload into an otherwise-trusted repo.
  The workspace's own `.git/hooks` directory is now layered read-only
  (same pattern as the `~/.claude` overlays below), so planting a hook
  file directly is closed - accepted breakage: installing hooks
  *in-session* (`husky`, `pre-commit install`) now fails, which is the
  point. `core.hooksPath` and `.claude/settings.local.json` aren't
  overlaid (they're config, not fixed paths a static mount can cover) and
  remain fully writable; the exit-time audit below reports changes to
  either, but only after the session ends - it doesn't stop them.
- `bin/dejima-audit` snapshots host-persistence surfaces before each
  run and diffs them after the container exits: `.git/config` (and worktree
  `config.worktree`) keys that run a command on the next `git` -
  `core.hooksPath`, `core.fsmonitor`, `core.sshCommand`,
  `credential.helper`, `core.pager`, `pager.*`, `core.editor`,
  `sequence.editor`, `gpg.program`, `diff.external`, `merge.*.driver`,
  `diff.*.command`, `filter.*.smudge`/`clean`/`process`, `diff.*.textconv`,
  `include.path`/`includeif.*.path` (config indirection - these can point at
  a planted file that itself sets an exec key, so the exec key never
  appears in `.git/config` directly), `!`-shell aliases - plus content
  changes under the workspace's `.claude/`, `.mcp.json`, `.envrc`,
  `.vscode/`, and `.git/hooks/` (symlinks included - a repointed symlink is
  hashed by its target, not just its content), plus cross-project writes
  under `~/.claude/projects` (see below). When the mounted workspace *is*
  this repo's own sandbox itself (see the trusted-computing-base note
  further below), it also diffs content hashes of the sandbox's own trusted
  computing base - `bin/`, `hooks/`, `docker/`, `install.sh`,
  `test/` - under that workspace. It's **advisory only**: it fires *after*
  the session has already ended, so a report of a planted `core.hooksPath`
  or hook file is something to read and clean up *before* the next `git`
  or `claude` in that repo, not something that was blocked. It's silent when nothing
  changed, and never affects the session's own exit code even if it can't
  complete. It doesn't cover `$SANDBOX_SHARE_DIR` (see "Shared scratch
  space") - that hand-off path stays unaudited - and its coverage is a
  fixed list of known Claude Code config surfaces, not a general integrity
  check, so a future config surface this list hasn't been taught about yet
  would go unreported.
- `~/.claude/projects` (session transcripts and per-project memory) is
  **not** mounted read-only, unlike the other `~/.claude` overlays above -
  deliberately. Scoping a read-only overlay to "the current project's slug"
  would break the sandbox's own worktree workflow: a session running in
  `WORKSPACE/.worktrees/<branch>` writes to a *different* projects slug
  than the parent repo, so a slug-scoped overlay would either block that
  legitimate write or have to be widened until it stopped protecting
  anything. Instead, cross-project writes are **detected, not prevented**:
  the exit-time audit above flags any write during the session to another
  project's `~/.claude/projects/<slug>` directory, excluding the current
  project's own slug and its worktree children. That's after-the-fact
  reporting of transcript/memory poisoning in *other* projects, not a
  block on it happening. Residual even within that: the current project's
  own transcripts/memory stay fully writable throughout, since Claude Code
  needs that for host-side `claude --resume` to work; and detection keys
  off each slug's max file mtime, so an edit to a file that isn't already
  that project's newest doesn't advance the max and goes unflagged. A
  read-only mount for `projects/` remains a possible future option if
  Claude Code is confirmed to fail cleanly (not hang, as `~/.claude.json`
  did) when a write to it is blocked.
- Allowing egress to a domain at all creates a channel for exfiltrating data
  through *that service's own request surface* (query strings, lookups,
  etc.), not just to a literal attacker-controlled destination. Domain-level
  allowlisting closes off reaching somewhere new; it can't inspect or
  restrict what gets sent to somewhere already trusted for normal operation
  (installing packages, calling the model API). That's a structural limit of
  allowlist-only firewalls in general, not something specific to this setup,
  and nothing here addresses it.
- This is container-level isolation (Linux namespaces plus a small
  capability set), not VM-level isolation - no gVisor/Firecracker or
  similar. It shares the host kernel, so a container-escape vulnerability
  would defeat every other control described here at once.
- Everything in this document has been verified by hand, at a point in
  time - there's no automated test suite re-checking these properties on
  every change, so a future edit could silently reintroduce a gap. This has
  already happened once in this file's own history (a missing `ipset`
  dedup flag broke firewall startup entirely, twice, on two different
  ipsets, before being caught).
- The Anthropic OAuth credential (`~/.claude/.credentials.json`) never
  enters the container. `bin/dejima` starts a host-side proxy
  (`bin/dejima-anthropic-proxy`) on a per-session unix socket,
  mounts an empty file over `.credentials.json` (the parent `~/.claude`
  mount stays read-write, so a single-file mask is the mechanism), and
  hands Claude Code a placeholder token plus an `ANTHROPIC_BASE_URL`
  pointing at a loopback forwarder that pipes into the socket. The proxy
  strips the placeholder, injects the real access token per request, and
  owns OAuth refresh - rotated tokens are written back to the real host
  file atomically, so host-side sessions stay logged in. What remains is
  session-scoped: a compromised session can still *use* the model API as
  you while it runs (that's inherent to the sandbox working at all), but
  it can no longer read a durable credential and exfiltrate it for
  offline use via the other allowed egress destinations (npm, GitHub,
  your Gitea host). Caveats: `/login` inside the container doesn't work
  while the proxy is on; the refresh flow mirrors a Claude Code internal
  and may break if upstream changes it, in which case the proxy fails
  loudly (launch abort, 502s on API calls) rather than silently.
  `SANDBOX_CREDENTIAL_PROXY=0` is the kill switch, restoring the previous
  behavior - the credential mounted into the container, readable by a
  compromised session. Setups without a `claudeAiOauth` block (API-key
  auth) skip the proxy automatically; there's no stored subscription
  credential to protect.
- `settings.json`, `CLAUDE.md`, `plugins/`, `hooks/`, `skills/`, `commands/`,
  `agents/`, and `output-styles/` under `~/.claude` are layered back
  read-only on top of the (otherwise read-write) `~/.claude` mount. Hooks
  execute automatically with no separate approval step, skills can ship
  executable scripts, and commands/agents/output-styles are prompt text
  loaded into a later host session, so without this a compromised session
  could plant a backdoored hook - including by unlinking one of
  `install.sh`'s hook symlinks and dropping a plain file in its place, since
  the dynamic per-target mounts `bin/dejima` adds at launch only
  protect symlink targets that resolve *outside* `~/.claude`, never this
  directory itself - rewrite `CLAUDE.md` with injected instructions, tamper
  with plugin code, or drop a malicious skill/command/agent/output-style
  file - something that would then run or load **unsandboxed on the host**
  the next time Claude Code starts there, turning a single compromised
  sandbox session into persistent host compromise. `skills/`, `commands/`,
  `agents/`, and `output-styles/` may not exist yet on a given host, so
  `bin/dejima` pre-creates them at launch (empty is fine) - a
  read-only overlay only applies to a directory that already exists, and
  without pre-creation a compromised session could create the directory
  itself first, then populate it, before the overlay ever had something to
  sit on top of. Everything else under `~/.claude` (session/project
  history, caches) stays read-write, since it's runtime state Claude Code
  needs to update - this list is a denylist of
  known code/config surfaces, not an allowlist, so it has to be kept in
  step with whatever new config surfaces Claude Code adds.
- `~/.claude/statusline.sh` (referenced by `settings.json`'s
  `statusLine.command` and executed on the host) is bind-mounted onto
  itself read-only by `bin/dejima`, for the same reason as the
  list above - to stop a compromised session from unlinking it and dropping
  its own script in its place. **Confirmed against a live container**
  (`test/runtime.bats`'s statusline.sh tests): this reliably blocks
  replacement when `statusline.sh` is a plain regular file. It does
  **not** when `statusline.sh` is a symlink (the common case - typically
  into a dotfiles checkout): Docker/runc resolves the bind-mount
  destination through the symlink to its target directory rather than
  binding to the symlink dentry itself, so the symlink entry stays on the
  writable `~/.claude` mount, still replaceable. There is no mount-based
  fix for this (`~/.claude` can't be made read-only - session history has
  to stay writable). The compensating control is detection, not
  prevention: `bin/dejima-audit` hashes `statusline.sh` (following
  a symlink to its target *path string*, so a repointed or replaced
  symlink is caught even though its own inode doesn't change) and reports
  it as a host-code-execution finding when the session exits. This is a
  defense-in-depth gap, not an open one: exploiting it requires a sandbox
  session that's already compromised, and that compromise is caught on
  exit either way.
- `~/.claude.json` mixes that same kind of live state (project registry,
  usage stats, caches) with config (`mcpServers`). Unlike the four above,
  it can't just be layered read-only: Claude Code does an atomic
  write-temp-then-rename against it during normal startup, before login
  even completes, and a read-only file makes that **hang** instead of
  failing cleanly (confirmed against a real read-only copy of this file -
  upstream bug: [anthropics/claude-code#29162](https://github.com/anthropics/claude-code/issues/29162)).
  Instead, `bin/dejima` generates a throwaway copy of the file at
  launch (seeded from the real file, same "generate a sandbox-specific
  file on the host" pattern as the generated `settings.json` copy above)
  and mounts *that* read-write in its place; the copy is discarded,
  unmodified in the real file, when the session ends. A compromised
  session can add whatever it wants to `mcpServers` (or anything else in
  the file) - it never reaches the real `~/.claude.json`, so there's
  nothing to persist. This also means multiple concurrent sandbox sessions
  never contend over the same file - each gets its own independent copy.

  ### Throwaway ~/.claude.json: what doesn't carry over

  Because nothing writes back, anything a *sandboxed* session would
  normally have caused Claude Code to record into `~/.claude.json` is lost
  when that session ends, instead of showing up in a later host-side
  `claude` run. Concretely, as of the fields this file holds today:

  - **Per-project trust/approval state** - `hasTrustDialogAccepted`,
    `allowedTools`, `enabledMcpjsonServers`/`disabledMcpjsonServers` - for
    any project directory opened only inside the sandbox. Opening that same
    project on the host later re-prompts for whatever it would have
    prompted for outside the sandbox too. Largely moot today since the
    sandbox always runs `--dangerously-skip-permissions`, but the trust
    dialog is a separate gate from tool-permission prompts.
  - **`mcpServers` additions or edits** - the point of this fix, not an
    incidental side effect. Nothing added or changed here during a
    sandboxed session ever reaches the real file.
  - **Session/usage telemetry** - `lastCost`, `lastDuration`,
    `lastTotalInputTokens`/`lastTotalOutputTokens`, `lastModelUsage`,
    `lastSessionId`, `mcpContextUris`, and similar per-project fields.
    Sandbox activity won't show up in host-side usage totals or in
    `claude --resume`'s "last session" metadata for that project.
  - **Global counters and caches** - `numStartups`, `firstStartTime`,
    `cachedGrowthBookFeatures`, `changelogLastFetched`,
    `announcementImpressions`, `tipsHistory`, `feedbackSurveyState`, and
    similar top-level bookkeeping. Purely cosmetic - these get refetched or
    recomputed as needed; sandbox runs just don't contribute to the host's
    copies of them.
  - **`oauthAccount`/`userID`/`machineID`** are read fresh from the real
    file at the start of every sandbox launch, so authentication carries in
    normally each time; anything that changes about them *during* a
    sandboxed session (e.g. a token refresh) doesn't carry back out. Worth
    re-checking if a future Claude Code version starts relying on that for
    normal operation.
- DNS resolution itself is allowlisted (see "DNS is allowlisted too" above),
  not just the IP connections made afterward, closing off exfiltration via
  encoding data into query names to an attacker-controlled domain - verified
  a non-allowlisted domain gets refused outright (`status: REFUSED`) rather
  than resolving and then only failing to connect.
- Don't mount other host secrets (`~/.ssh` private keys, cloud credential
  files) into the container. Git push auth goes through the forwarded SSH
  agent instead, which never exposes the key material itself - though note
  the agent will sign for *any* Gitea repo your key has access to, not just
  the mounted project, and the firewall's Gitea allowlist is host-based
  rather than repo-scoped, so a compromised session can still reach (and
  push to) other repos on that host you have access to. This doesn't extend
  to GitHub by default: port 22 there is blocked unless `ALLOW_GITHUB_PUSH=1`
  is set, so the forwarded agent has no transport to use for it at all
  otherwise (see "GitHub push: blocked by default, optional opt-in" above).
- `SANDBOX_SSH_KEY` (see "Headless git push without agent forwarding") is a
  second, independent credential-loading path with the same "signs for any
  Gitea repo it has access to" shape as the forwarded agent above - the
  mitigation is that it's meant to be a dedicated deploy key scoped to only
  the repos that actually need push access, not your personal identity.
  That scoping is a convention, not something enforced here: nothing checks
  what `SANDBOX_SSH_KEY` actually points at, so pointing it at your real
  `~/.ssh/id_ed25519`/`id_rsa` instead of a dedicated key would load your
  full personal identity into the container for the whole session (`bin/
  dejima` warns if this looks like it might be happening - see
  below - but doesn't block it). The key source itself is mounted read-only
  at `/root/...`, not under the sandbox user's own home, specifically so
  that user (which the session actually runs as) has no path to read the
  raw key material - only the agent socket it's loaded into.
- The gitconfig copy `bin/dejima` generates (see that mount's
  comment in `docker-compose.yml`) carries over whatever's in your real
  `~/.gitconfig` verbatim. If yours has inline credentials (a
  `[credential]` token, a `url.<token@>.insteadOf` rewrite, a
  `credential.helper store` path), those enter the container along with
  it - an unadvertised secret-carrying path distinct from the
  SSH-agent/token story documented above. Keep credentials out of your
  global gitconfig, or expect them to be reachable from inside the
  sandbox.
- The sandbox's own user (matching your host user — see "Config parity"
  above) has no `sudo`/setuid path back to root once the container is up:
  `entrypoint.sh` runs as root, sets up the firewall directly, then drops to
  that user via `gosu` before execing `$SANDBOX_CMD`. A compromised session can't
  re-run `init-firewall.sh` with a wider allowlist to open its own
  exfiltration path. Verified: capabilities (`NET_ADMIN`/`NET_RAW`) are
  cleared from the effective/permitted sets on the `gosu` drop, and that
  user gets a permission error running `iptables` directly.
- The approval store (`${DEJIMA_CONFIG_DIR:-$HOME/.config/dejima}`,
  see "Global and per-project domains and dependencies" above) lives outside
  this repo, and outside every project mount, by default - unlike a
  project's own `.dejima/` declaration files, it's never
  bind-mounted into the container, so a compromised
  session has no path to write to it at all, let alone plant something for
  the *next* launch to pick up. Its files are read by a small
  line-oriented parser (`approved_entries` in
  `bin/dejima-project-lib.sh`), never sourced or executed, and are
  written only by the CLIs (`dejima-allow`, `dejima-dep`,
  `dejima-project`) a human runs on the host. `bin/dejima`
  warns at launch whenever the resolved store path — default or overridden
  via `DEJIMA_CONFIG_DIR` — lands under the mounted workspace,
  rather than silently trusting it.
- When the mounted workspace *is* this repo itself, `bin/dejima`
  warns at launch that the repo's own trusted computing base - `bin/`,
  `hooks/`, `docker/`, `install.sh` (also `test/`, per the
  exit-time audit's exact TCB path list above) - is writable for the
  session (it's inside the project mount, which has no write protection,
  per above), and that the exit-time audit will report any changes to it.
  That's a warning and a post-hoc report, not a block: a compromised
  session can still edit those files during the run, and whatever it
  changes takes effect the *next* time `bin/dejima` itself runs,
  not the current one.

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

`static.bats` greps the repo's own files - no sudo in the `Dockerfile`, every
`ipset add` is duplicate-safe, no `docker.sock`/host-credential mounts, the
`~/.claude` read-only overlay lines are present, `bin/dejima-allow`
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
covers everything under "Remote access": `remote.conf` parsing, the session
registry, and the properties the feature's security rests on - that the
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
| `docker/Dockerfile` | Base image, dev tools, nvim, Claude Code + wrapper, `gitea-pr` |
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
| `hooks/dejima-notify.sh` | `Notification`/`Stop` hook: drops an empty `waiting`/`done` marker for a remote-enabled session - see "Remote access" |
| `bin/dejima-attach` | Lists live sessions and attaches to one; the shared core behind both remote front doors |
| `bin/dejima-audit` | Advisory exit-time diff of host-persistence surfaces (git config, `.claude/`, etc.) |
| `bin/dejima-dep` | Review and approve project dependencies declared in `.dejima/dependencies` |
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
