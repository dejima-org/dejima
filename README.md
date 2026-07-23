# claude-sandbox

Runs Claude Code inside a Docker container with `--dangerously-skip-permissions`
(no permission prompts, all tool use auto-accepted) against a project mounted
from the host. Based on
[Anthropic's reference dev container](https://github.com/anthropics/claude-code/tree/main/.devcontainer):
same base image, non-root user, and egress-firewall approach, adapted to run
via `docker compose` directly instead of through a VS Code dev container, and
extended with a `gitea-pr` helper for opening/iterating on PRs against a
Gitea (or Forgejo - see Prerequisites below) instance, and an optional
editor-driven workflow in place of bare Claude Code (see "Usage" below).

This repository only holds the tooling. It is **not** where any project
lives — the project you point it at is bind-mounted into the container at
runtime from wherever it actually sits on disk.

## Prerequisites

- Docker with the `docker compose` v2 plugin.
- `ssh-agent` running with the key for your Gitea remote(s) added
  (`ssh-add -l` should list it). The container never sees your private key,
  only a forwarded agent socket. `bin/claude-sandbox` warns (non-fatally) at
  launch if the agent has zero identities loaded - the socket still forwards
  fine either way, but git-over-ssh will fail until you `ssh-add` a key. That
  takes effect immediately in an already-running session too (it's a live
  reference to the same host agent process, not a snapshot) - no need to
  restart the sandbox after `ssh-add`ing.
  For a sandbox that needs to keep working unattended after your client
  disconnects, see "Headless git push without agent forwarding" below —
  `SANDBOX_SSH_KEY` is an alternative to this forwarded-agent requirement,
  not just an addition to it.
- `GITEA_SSH_HOST` and `GITEA_API` exported in your shell (same variables
  `bin/gitea-pr` already needs — see its `require_config`), and a token
  available either via `GITEA_TOKEN` in the environment or at
  `~/.config/gitea/token`. `gitea-pr` and these variable names target Gitea's
  API specifically, but [Forgejo](https://forgejo.org/) (a fork of Gitea)
  exposes a compatible `/api/v1` surface - pointing `GITEA_API` at a Forgejo
  instance works unmodified.
- Optional: a **read-only** fine-grained GitHub PAT (GitHub → Settings →
  Developer settings → Fine-grained tokens → generate, with Contents and
  Metadata set to read-only, no write scopes) for `gh`/private-repo HTTPS
  access, available via `GH_TOKEN` in the environment or at
  `~/.config/gh/sandbox-token`. Don't use a normal `gh auth login` session
  here — that's write-capable, which defeats the point (see "GitHub push:
  blocked by default, optional opt-in" below). Without it, public GitHub
  repos still clone/fetch fine anonymously over HTTPS; only private repos and
  `gh` API calls need it.
- Optional: `LOKI_URL` (a base URL, e.g. `http://loki.internal:3100`) to ship
  DNS-query and firewall allow/reject logs to a Loki push endpoint - see
  "Network request logging" below. Logging is skipped entirely if unset.

## Usage

```sh
bin/claude-sandbox                        # sandbox the current directory
bin/claude-sandbox ~/repos/some-project
```

By default the container's entry point is bare `claude` (the wrapped binary,
always running with `--dangerously-skip-permissions` regardless of how it's
invoked - see `docker/claude-wrapper.sh`), so a fresh clone of this repo works
with no editor setup at all.

Typical loop: point it at a project, ask Claude to implement something and
open a PR (it has `gitea-pr` on `PATH`); from the host, `gitea-pr comments <PR#>`
to pull review feedback, feed it back in, repeat.

### Using a different editor/application

Set `SANDBOX_CMD` to run something else as the container's main process
instead - for example, an editor with its own Claude Code integration:

```sh
SANDBOX_CMD=nvim bin/claude-sandbox ~/repos/some-project
```

This repo doesn't ship or assume any particular editor config - `nvim` (or
whatever `SANDBOX_CMD` names) runs unconfigured unless you also point
`SANDBOX_NVIM_CONFIG` at a real config directory on the host:

```sh
SANDBOX_CMD=nvim SANDBOX_NVIM_CONFIG=~/.config/nvim bin/claude-sandbox ~/repos/some-project
```

`SANDBOX_NVIM_CONFIG` is bind-mounted read-only at `~/.config/nvim` inside the
container. Set both in your own shell profile if you use this mode regularly.

## Config parity with your host Claude Code setup

`~/.claude` and `~/.claude.json` are bind-mounted read-write from the host
into the container, so global `CLAUDE.md`, settings, hooks, plugins, MCP
server config, and your existing login/credentials all carry over
automatically — the container is a faithful copy of this setup, not a
separate identity. There's no separate first-run login.

The project directory is mounted at the *same absolute path* inside the
container as on the host (not a fixed `/workspace`), so Claude Code's
project/session-history keying lines up between host and container. A
session started in the sandbox can be resumed on the host afterward with
`claude --resume <session-id>`.

The container's own user is built to match yours exactly — same username,
uid, gid, and home directory (`bin/claude-sandbox` passes these as Docker
build args; see `Dockerfile`). This is what makes `$HOME`-relative
assumptions actually work inside the container instead of just superficially
resembling your setup — your dotfiles, and Claude Code's own plugin
bookkeeping (which records install locations as literal host-absolute
paths, not relative to whatever `$HOME` happens to be), resolve to the same
paths on both sides. The build defaults to `node`/1000/1000/`/home/node` if
these aren't supplied, so building the image directly (bypassing
`bin/claude-sandbox`) still works, just without this parity. On a shared
machine, the built image is tagged per-user (`claude-sandbox:<username>`) so
two accounts building concurrently don't clobber each other's image.

Caveat: MCP servers or hooks that shell out to host-specific binaries (e.g. a
browser for Playwright, a language runtime not installed in this image) may
not work inside the container unless that tooling is also added to the
`Dockerfile`.

Your global `~/.gitconfig` (`user.name`/`user.email` and the like) is also
carried over, so commits made inside the sandbox have the right identity
without any extra setup - falls back to an empty config if you don't have
one, it's not a hard requirement. It's a throwaway copy rather than the
real file, in its own directory rather than mounted directly at
`~/.gitconfig` (`GIT_CONFIG_GLOBAL` points git at it instead) - `gh auth
setup-git` needs to write a credential-helper entry into it, and both a
read-only mount and a single-file bind mount at `~/.gitconfig` break that
write in different ways. Nothing written to it during a session reaches
your real `~/.gitconfig`.

### Headless git push without agent forwarding

Agent forwarding (the default — see Prerequisites) ties the sandbox's SSH
access to whichever client's agent is currently forwarded. On a devbox
reached over SSH+tmux, that agent belongs to whichever client connected —
when that client disconnects, the forwarded socket dies with it, breaking
git-over-ssh for anything still running headless in the sandbox.

For sandboxes meant to keep running unattended, generate a dedicated,
purpose-built keypair instead — not your personal key:

```sh
ssh-keygen -t ed25519 -N '' -f ~/.ssh/claude-sandbox_ed25519
```

Passphrase-less is deliberate: headless operation has no human to answer a
prompt, and this is meant to be a low-privilege credential that only ever
lives inside the container, not your personal identity. Add the public
half as a Gitea deploy key scoped to only the repos that actually need push
access, then:

```sh
SANDBOX_SSH_KEY=~/.ssh/claude-sandbox_ed25519 bin/claude-sandbox ~/repos/some-project
```

The key is bind-mounted read-only at `/root/.ssh-sandbox-key-src` — under
`/root`, not `$SANDBOX_HOME` — so only entrypoint.sh's root-run startup code
can ever read it; the sandbox user (which the session actually runs as) has
no path to that directory at all. At container start, `entrypoint.sh` loads
it into a fresh `ssh-agent` running inside the container itself —
independent of the forwarded socket — copies it out just long enough to do
that, and deletes the copy immediately afterward. A compromised session can
use the agent's socket to sign git-over-ssh operations (bounded by whatever
the deploy key has push access to), but can't read the raw key material
itself. When `SANDBOX_SSH_KEY` is set, a live forwarded agent is no longer
required to start the sandbox at all.

## Shared scratch space

`~/shared` inside the container is a read-write bind mount of a real host
directory (`$SANDBOX_SHARE_DIR`, default `~/.local/share/claude-sandbox/shared`,
created automatically) - separate from the project mount, for passing files
(screenshots, temp scripts) back and forth with a sandboxed session without
touching the actual project checkout. It persists across sessions since it's
a real directory, not a container volume. Set `SANDBOX_SHARE_DIR` to point
it somewhere else.

`~/specs` is also bind-mounted read-write, at the fixed host path `~/specs`
(created automatically if it doesn't exist yet) - not configurable like
`SANDBOX_SHARE_DIR`, since it exists to make the global `CLAUDE.md`
convention of writing specs to `~/specs/` (also carried into the container)
actually work there instead of writing into a path that vanishes with the
session.

## Testing frontend changes

Playwright (Chromium) is pre-installed, browser included - `require
("playwright")` works from any script, anywhere in the container, not just
a project with its own `npm install playwright`. Both the npm package and
the matching Chromium build are baked in at image build time, so a session
never needs network access for either.

Testing against a project's own local dev server needs no firewall changes
at all - `localhost`/loopback traffic never goes through the egress
firewall in the first place. Testing against a real external site works
the same as any other network use: the domain needs to be on the allowlist
(`ALLOWED_DOMAINS`, or `bin/claude-sandbox-allow <domain>` for a running
session) - verified the firewall applies to the browser's own traffic
exactly like everything else (a non-allowlisted domain gets blocked from
inside the browser too, not just from `curl`/`git`).

If a project has its *own* pinned `playwright`/`@playwright/test`
devDependency at a different version than the one baked in here, its
`npm install` may still try to download a matching Chromium build from
Playwright's own CDN, which isn't on the default allowlist - allow it the
same way as any other one-off domain need if that comes up.

Chromium's own internal process sandbox is best-effort here, not something
to rely on: it launches without erroring, but its setuid sandbox helper
isn't actually setuid in this image, and this host has the same
unprivileged-userns restriction that keeps Claude Code's own internal
sandboxing (see Security notes) from working either - so its namespace-
based isolation almost certainly isn't active, Chromium just doesn't
hard-fail the way `bubblewrap` does when it's missing. Not treated as a
real boundary: this container is already the boundary that matters, and a
compromised session already has full bash access as the container's own
user regardless, which a Chromium exploit couldn't exceed.

## Sandbox self-awareness

A `SessionStart` hook (`~/.claude/hooks/sandbox-context.sh`, registered in
`~/.claude/settings.json`) checks for the `CLAUDE_SANDBOX` environment
variable this container sets, and when present, injects a reminder that the
session is running in a disposable, firewalled container and should stay
within the task at hand — and that if a task genuinely needs to break out of
the sandbox (broader network access, host-level changes, GUI/hardware), it
should stop and tell the user rather than trying to work around the
firewall, since the same session can be resumed unrestricted on the host via
`claude --resume`. It's a no-op outside the container. This is on top of the
existing `deny-dangerous-bash.sh` `PreToolUse` hook, which also applies here
since `~/.claude` is shared.

`git-push-guard.sh` (also `PreToolUse`/`Bash`, also `CLAUDE_SANDBOX`-gated)
blocks any `git push` whose resolved remote isn't the Gitea host, and any
push to `main`/`master` even there — the sandbox workflow is feature branch
+ `gitea-pr create`, never a direct push. Like the other hooks, this is a
fast-fail guard against an overeager agent, not a hard security boundary: a
sandbox session has full shell access and could in principle edit
`.git/config` to route around it. GitHub push is blocked by default here too
(on top of the firewall - see "GitHub push: blocked by default, optional
opt-in" below), unless `ALLOW_GITHUB_PUSH=1` is set. For "never pushes to
main/master", the authoritative version of that is branch protection on the
remote repo itself, which this doesn't set up for you.

sandbox-context.sh also tells the agent the actual workflow to follow
proactively, not just what's blocked: do new work in a `git worktree`
rather than switching branches in the mounted checkout in place (that's the
user's real working copy), then push the feature branch and run
`gitea-pr create` from the worktree. The worktree has to live *under* the
mounted project directory (e.g. `.worktrees/<branch>`, not `../<branch>`) -
only the exact bind-mounted path is backed by real host storage, so a
worktree created as a sibling of the project (or anywhere under `$HOME`)
looks fine but silently disappears with the container, worktree and all.

## Network egress firewall

On start, the container runs an allowlist-only `iptables`/`ipset` firewall
(`init-firewall.sh`), matching the reference dev container. Allowed by
default: DNS resolution via a local DNS proxy (see "DNS is allowlisted too"
below), the Docker host itself (not its whole subnet), GitHub's published IP
ranges (port 443 only - see "GitHub push: blocked by default, optional
opt-in" below),
`release-assets.githubusercontent.com` (GitHub release assets - e.g. mason's
own registry index - redirect here, a separate CDN from github.com's own
IPs), `registry.npmjs.org`, `pypi.org` and `files.pythonhosted.org` (mason's
Python-based LSP tools - `ruff`, `basedpyright`, `debugpy` - install via
pip), `proxy.golang.org` and `sum.golang.org` (`go build`/`go mod download`'s
module proxy and checksum database), `api.anthropic.com`, and whatever hosts
`GITEA_SSH_HOST`/`GITEA_API`
resolve to — that last group isn't port-restricted, so git-over-ssh to Gitea
works without a separate blanket "port 22 to anywhere" rule. Set
`ALLOWED_DOMAINS` (space-separated) in the environment to allow more (e.g.
`crates.io` for a Rust project needing more than what mason/npm already
cover). Everything else is rejected. Set `ENABLE_FIREWALL=0` to disable it
entirely (e.g. for debugging a blocked domain).

IPv6 is blocked outright (`ip6tables` policy DROP on INPUT/OUTPUT/FORWARD,
and dnsmasq strips AAAA answers so nothing wastes a connection attempt on an
address that could never be reached) - there's no IPv6 equivalent of the
allowlist above, so leaving it open would bypass the entire firewall on any
host with IPv6 egress enabled.

If your Gitea host is only resolvable via a LAN-local DNS server, make sure
the Docker host itself can resolve it — containers inherit the host's
resolver by default.

### DNS is allowlisted too

Resolution itself is restricted, not just the IP connections made
afterward: `dns-proxy.sh` runs a local `dnsmasq` bound to 127.0.0.1 with no
fallback resolver, and `/etc/resolv.conf` is repointed at it. Only names
matching the same allowlist as above (plus `github.com`/
`githubusercontent.com`/`githubassets.com`, needed since GitHub is
allowlisted by IP range rather than by resolving those names - see
`fixed-domains.sh`) get forwarded to Docker's real resolver; anything else
gets no upstream configured at all and is refused outright. Without this, a
compromised session could still exfiltrate data by encoding it into query
names to an attacker-controlled domain even though it could never open a
direct connection there - IP-based filtering alone doesn't stop that, since
the DNS query itself was never restricted.

### Adding a domain to a running session

`ALLOWED_DOMAINS` only takes effect at container start. For a domain a
*running* session needs right now, run from the host (not inside the
sandbox — it has no privilege to do this itself):

```sh
bin/claude-sandbox-allow crates.io                # this session only
bin/claude-sandbox-allow crates.io --global       # + persist in config/profile
```

It first adds the domain to the running dnsmasq's allowlist (appends a
`server=` line to its servers-file and sends `SIGHUP` to reload just that
file - no restart), then resolves it through the now-unblocked container
resolver and adds the IP(s) to the running firewall's `ipset`, all via
`docker exec -u root`. `--global` also appends the domain to
`ALLOWED_DOMAINS` in `config/profile` for future sessions; source your shell
(or open a new one) for that part to take effect. If more than one
claude-sandbox container is running, pass `--container <name>` to
disambiguate (`docker ps` to find it).

The sandbox-context.sh `SessionStart` hook tells the agent to ask for this
by name when a task is blocked on a single missing domain, rather than
stopping the whole session over it.

## Network request logging

If `LOKI_URL` is set (see Prerequisites), every DNS query and every new
outbound connection attempt - allowed or rejected - is shipped to that Loki
endpoint. Two sources, both tailed and pushed by `log-shipper.sh`:

- `dns-proxy.sh`'s dnsmasq logs every query and whether it was forwarded
  (allowed) or refused (not on the allowlist) - labeled `job=claude-sandbox-dns`.
- `init-firewall.sh` tags its terminal ACCEPT/REJECT rules with `NFLOG`
  (group 1 for allowed, group 2 for rejected), which `ulogd2`
  (`ulogd.conf`) turns into JSON lines with source/dest IP, port, and an
  `action` field - labeled `job=claude-sandbox-net`. Only new connection
  attempts are logged, not every packet: the firewall's existing
  ESTABLISHED,RELATED rule short-circuits the rest of a connection before it
  ever reaches the tagged rules.

This is visibility on top of the firewall/DNS-proxy enforcement above, not a
substitute for it - nothing about logging changes what's actually allowed to
resolve or connect.

### Viewing logs in Grafana

Nothing sandbox-specific needed on the Grafana side beyond a Loki data
source pointed at wherever `LOKI_URL` resolves to (Connections → Data
sources → Loki, if one isn't already configured against that instance) -
`log-shipper.sh` pushes directly to Loki's HTTP API, there's no Prometheus
scrape target or exporter involved.

In Grafana's Explore view (or a dashboard panel with a Loki query), both
streams are selectable by their `job` label:

```logql
{job="claude-sandbox-dns"}                          # every DNS query + verdict
{job="claude-sandbox-net"}                          # every connection attempt, as JSON
```

Useful filters on top of those:

```logql
# DNS lookups that got refused (not on the allowlist)
{job="claude-sandbox-dns"} |= "REFUSED"

# Rejected connections only (parses ulogd2's JSON, filters on its action field)
{job="claude-sandbox-net"} | json | action="blocked"

# Both streams together, e.g. to watch a live session across sources
{source="claude-sandbox"}
```

`{job="claude-sandbox-net"}` lines are one full ulogd2 JSON object per
connection attempt (`| json` in a query unpacks fields like `dest_ip`,
`dest_port`, `action`) - Loki's Explore view shows these expandable/
pretty-printed by default, no extra parsing setup needed.

## GitHub push: blocked by default, optional opt-in

The sandbox can always read from GitHub (clone, fetch, `gh` API calls). By
**default**, it can never push there, enforced at the network layer, not just
by the `git-push-guard.sh` hook: GitHub's IP ranges are only allowlisted on
port 443. Port 22 is unreachable, so SSH-based push (which could otherwise
use the forwarded agent's real key - agent forwarding doesn't distinguish
"push" from "pull") has no transport to use at all, regardless of what any
hook does or doesn't catch.

**This is opt-in, not hardcoded.** Set `ALLOW_GITHUB_PUSH=1` to open port 22
to GitHub and let `git-push-guard.sh` accept `github.com`/`ssh.github.com` as
a push destination (the no-direct-to-main rule still applies there too):

```sh
ALLOW_GITHUB_PUSH=1 bin/claude-sandbox ~/repos/some-project
```

**Read this before turning it on.** Whether a push actually succeeds still
depends entirely on what SSH key material is loaded into the agent - the
forwarded socket (`SSH_AUTH_SOCK`), or `SANDBOX_SSH_KEY` (see "Headless git
push without agent forwarding" above). A forwarded personal agent with your
normal GitHub key loaded would let a compromised session push to **any**
repo that key has write access to, not just the one you intended - agent
forwarding doesn't distinguish push from pull, and GitHub deploy keys aren't
involved unless you specifically set one up. Use a dedicated,
**repo-scoped GitHub deploy key** via `SANDBOX_SSH_KEY` instead of a
forwarded personal agent whenever `ALLOW_GITHUB_PUSH=1` - that's what
actually limits the blast radius, the same pattern already recommended for
Gitea's `SANDBOX_SSH_KEY` above. `ALLOW_GITHUB_PUSH` only changes the
firewall/hook's *host* check; it does not add any new credential-loading
path of its own.

`GH_TOKEN` (see Prerequisites) must stay a **read-only** fine-grained PAT
regardless of this setting - that guidance was never enforced by this flag
and isn't changed by it. `gh auth setup-git` (run at container start if
`GH_TOKEN` is set) points git's github.com HTTPS credential helper at `gh`,
which only ever holds whatever token `GH_TOKEN` provides; a write-scoped
token there would make HTTPS push possible independent of `ALLOW_GITHUB_PUSH`,
so don't use one.

`ALLOW_GITHUB_PUSH` is a per-launch environment variable, not a persistent
global toggle - it only affects the one `bin/claude-sandbox` invocation it's
set for.

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
- Because `~/.claude` (including `.credentials.json`) is bind-mounted in,
  anything reachable from inside the container (the allowed domains above)
  is a potential exfiltration path for those credentials if a malicious repo
  manages to manipulate a session. The firewall limits this to
  Anthropic/npm/GitHub/your Gitea host, not the open internet.
- `settings.json`, `CLAUDE.md`, and `plugins/` under `~/.claude` are
  layered back read-only on top of the (otherwise read-write) `~/.claude`
  mount. Hooks execute automatically with no separate approval step, so
  without this a compromised session could plant a backdoored hook, rewrite
  `CLAUDE.md` with injected instructions, or tamper with plugin code -
  something that would then run **unsandboxed on the host** the next time
  Claude Code starts there, turning a single compromised sandbox session
  into persistent host compromise. Everything else under `~/.claude`
  (session/project history, credentials refresh, caches) stays read-write,
  since it's runtime state Claude Code needs to update.
  `~/.claude.json` is a single file mixing that same kind of live state with
  config (e.g. `mcpServers`, if ever set) and can't be split at the mount
  level, so it's left fully read-write - accepted as a residual risk rather
  than solved.
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
  claude-sandbox` warns if this looks like it might be happening - see
  below - but doesn't block it). The key source itself is mounted read-only
  at `/root/...`, not under the sandbox user's own home, specifically so
  that user (which the session actually runs as) has no path to read the
  raw key material - only the agent socket it's loaded into.
- The sandbox's own user (matching your host user — see "Config parity"
  above) has no `sudo`/setuid path back to root once the container is up:
  `entrypoint.sh` runs as root, sets up the firewall directly, then drops to
  that user via `gosu` before execing `$SANDBOX_CMD`. A compromised session can't
  re-run `init-firewall.sh` with a wider allowlist to open its own
  exfiltration path. Verified: capabilities (`NET_ADMIN`/`NET_RAW`) are
  cleared from the effective/permitted sets on the `gosu` drop, and that
  user gets a permission error running `iptables` directly.

## Tests

`test/` has a [bats](https://github.com/bats-core/bats-core) suite covering
the security invariants above - not a substitute for reading this document,
but a way to actually catch a future change silently breaking one of them
instead of finding out the hard way:

```sh
bats test/               # everything
bats test/static.bats     # fast, no Docker/build needed
SKIP_BUILD=1 bats test/runtime.bats   # reuse the current image
```

`static.bats` greps the repo's own files - no sudo in the `Dockerfile`, every
`ipset add` is duplicate-safe, no `docker.sock`/host-credential mounts, the
`~/.claude` read-only overlay lines are present, `bin/claude-sandbox-allow`
rejects a malicious domain argument. `runtime.bats` builds the image, boots
a real container running the actual `entrypoint.sh` (a `SANDBOX_TEST_MODE`
env var makes it stop just short of execing `$SANDBOX_CMD`, so the suite can attach
to a fully-initialized container instead of reimplementing its own copy of
the setup sequence), and asserts against it: IPv6 blocked, DNS/IP allowlist
enforcement in both directions, GitHub read-only, no working `sudo`/
`iptables`/`init-firewall.sh` as `node`, capabilities actually stripped
(not just absent from a `docker exec` that doesn't have them to begin
with), `ulogd2` unprivileged, and the dynamic-ipset CDN-rotation fix.

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
| `docker/log-shipper.sh` | Tails the dnsmasq/ulogd2 logs and ships them to `$LOKI_URL` |
| `docker/entrypoint.sh` | Runs as root: DNS proxy, firewall, logging, drops to the sandbox user via `gosu`, execs `$SANDBOX_CMD` |
| `docker/claude-wrapper.sh` | Shadows `claude` on `PATH` to always add `--dangerously-skip-permissions` |
| `docker/docker-compose.yml` | Wires up mounts/env; invoked via `bin/claude-sandbox`, not directly |
| `hooks/sandbox-context.sh` | `SessionStart` hook: injects sandbox context/workflow reminders |
| `hooks/git-push-guard.sh` | `PreToolUse` hook: blocks pushes outside the allowed host(s)/branches |
| `hooks/deny-dangerous-bash.sh` | `PreToolUse` hook: blocks obviously destructive Bash commands |
| `config/env` | Persists `ALLOWED_DOMAINS` across sessions (rewritten by `--global`) |

`bin/claude-sandbox` is the entry point — it resolves the project path,
checks for a live `ssh-agent`, loads `GITEA_TOKEN`/`GH_TOKEN` if not already
set, discovers which host directories need mounting for `~/.claude/hooks`
symlinks to resolve, and runs `docker compose run`. `bin/claude-sandbox-allow`
adds a domain to a running session's firewall from the host - see "Adding a
domain to a running session" above. `install.sh` installs the hooks into
`~/.claude/hooks` and registers them in `~/.claude/settings.json`.
