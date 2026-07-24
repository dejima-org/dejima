# claude-sandbox

Runs Claude Code inside a firewalled Docker container with
`--dangerously-skip-permissions` (no permission prompts, all tool use
auto-accepted), against a project bind-mounted from the host. Based on
[Anthropic's reference dev container](https://github.com/anthropics/claude-code/tree/main/.devcontainer),
adapted to run via `docker compose` directly and extended with a `gitea-pr`
helper for opening/iterating on PRs against Gitea or Forgejo, plus an
optional editor-driven workflow in place of bare Claude Code (see "Usage").

This repo only holds the tooling — it's not where any project lives. Point
it at a project on disk; that project is bind-mounted into the container at
runtime.

## Prerequisites

- Docker with the `docker compose` v2 plugin.
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
| `ALLOWED_DOMAINS` | unset | extra egress-allowed domains, space-separated |
| `SANDBOX_CMD` | `claude` | container's main process (e.g. `nvim`) |
| `SANDBOX_NVIM_CONFIG` | unset | nvim config dir, used when `SANDBOX_CMD=nvim` |
| `SANDBOX_EXTRA_MOUNTS` | unset | extra host paths (colon-separated) a personal config needs, mounted read-only at their own path |
| `SANDBOX_SHARE_DIR` | `~/.local/share/claude-sandbox/shared` | host-visible read/write scratch dir |
| `LOKI_URL` | unset | ship DNS/firewall logs to a Loki endpoint |
| `ENABLE_FIREWALL` | `1` | set to `0` to disable the egress firewall (debugging only) |

**Gitea/Forgejo is the default PR workflow** — `gitea-pr`, and the only push
target `git-push-guard.sh` allows by default. If you don't use Gitea/Forgejo,
skip `GITEA_*` entirely and set `ALLOW_GITHUB_PUSH=1` instead to push
straight to GitHub (see "GitHub push: blocked by default, optional opt-in"
below) — the two aren't both required, pick whichever matches your remote.
[Forgejo](https://forgejo.org/) works unmodified: it's a Gitea fork exposing
a compatible `/api/v1` surface, so pointing `GITEA_API` at a Forgejo instance
just works.

## Usage

```sh
bin/claude-sandbox                        # sandbox the current directory
bin/claude-sandbox ~/repos/some-project
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
SANDBOX_CMD=nvim bin/claude-sandbox ~/repos/some-project
```

Runs unconfigured unless you also set `SANDBOX_NVIM_CONFIG` to a real config
directory on the host (bind-mounted read-only at `~/.config/nvim` — lazy.nvim's
lockfile is the one exception, layered read-write on top so plugin syncs
don't fail on a read-only filesystem; nothing else in the config is
writable):

```sh
SANDBOX_CMD=nvim SANDBOX_NVIM_CONFIG=~/.config/nvim bin/claude-sandbox ~/repos/some-project
```

Set both in your shell profile if you use this mode regularly.

If your config references something outside that directory by absolute host
path (a helper script in a dotfiles `bin/`, say), bring it in with
`SANDBOX_EXTRA_MOUNTS` (colon-separated, mounted read-only at the same path):

```sh
SANDBOX_EXTRA_MOUNTS=~/dotfiles/bin bin/claude-sandbox ~/repos/some-project
```

## Config parity with your host Claude Code setup

`~/.claude` is bind-mounted read-write, so global `CLAUDE.md`, settings,
hooks, plugins, and your existing login/credentials all carry over
automatically — no separate first-run login. (`~/.claude.json` is handled
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
`bin/claude-sandbox`. Images are tagged per-user (`claude-sandbox:<username>`)
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
ssh-keygen -t ed25519 -N '' -f ~/.ssh/claude-sandbox_ed25519
```

Passphrase-less is deliberate — this is meant to be a low-privilege
credential living only inside the container, not your personal identity. Add
the public half as a Gitea deploy key scoped to just the repos that need
push access, then:

```sh
SANDBOX_SSH_KEY=~/.ssh/claude-sandbox_ed25519 bin/claude-sandbox ~/repos/some-project
```

`entrypoint.sh` loads it into a container-local `ssh-agent` at startup and
deletes the plaintext copy immediately after — the sandbox user itself never
has a path to the raw key, only the agent socket (see "Security notes" for
the full mount rationale). Setting `SANDBOX_SSH_KEY` means a live forwarded
agent is no longer required at all.

## Shared scratch space

`~/shared` is a read-write bind mount of `$SANDBOX_SHARE_DIR` (default
`~/.local/share/claude-sandbox/shared`, created automatically) — separate
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
needs to be on the allowlist like any other network use (`ALLOWED_DOMAINS`,
or `bin/claude-sandbox-allow <domain>` for a running session) — the firewall
applies to the browser's traffic exactly like `curl`/`git`.

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
reminder when `CLAUDE_SANDBOX` is set: the session is running in a
disposable, firewalled container and should stay within the task at hand —
if something genuinely needs to break out (broader network, host changes,
GUI/hardware), stop and ask rather than trying to work around the firewall,
since the same session can be resumed unrestricted on the host via
`claude --resume`. No-op outside the container. `deny-dangerous-bash.sh`
(`PreToolUse`) also applies here, since `~/.claude` is shared.

`git-push-guard.sh` (`PreToolUse`/`Bash`, also `CLAUDE_SANDBOX`-gated) blocks
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

Everything else is rejected. Set `ALLOWED_DOMAINS` (space-separated) to allow
more (e.g. `crates.io` for a Rust project), or `ENABLE_FIREWALL=0` to disable
the firewall entirely (debugging only).

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

`ALLOWED_DOMAINS` only takes effect at container start. For a domain a
*running* session needs right now, run from the host (not inside the
sandbox — it has no privilege to do this itself):

```sh
bin/claude-sandbox-allow crates.io                # this session only
bin/claude-sandbox-allow crates.io --global       # + persist in config/env
```

It first adds the domain to the running dnsmasq's allowlist (appends a
`server=` line to its servers-file and sends `SIGHUP` to reload just that
file - no restart), then resolves it through the now-unblocked container
resolver and adds the IP(s) to the running firewall's `ipset`, all via
`docker exec -u root`. `--global` also appends the domain to
`ALLOWED_DOMAINS` in `config/env` for future sessions - picked up
automatically by the next `bin/claude-sandbox` invocation, no sourcing
needed. If more than one
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
**default** it can never push there — enforced at the network layer, not
just by `git-push-guard.sh`: GitHub's IP ranges are only allowlisted on port
443. Port 22 is unreachable, so SSH-based push has no transport at all,
regardless of what any hook does or doesn't catch.

**Opt-in, not hardcoded** — set `ALLOW_GITHUB_PUSH=1` to open port 22 to
GitHub and let `git-push-guard.sh` accept `github.com`/`ssh.github.com` as a
push destination (the no-direct-to-main rule still applies):

```sh
ALLOW_GITHUB_PUSH=1 bin/claude-sandbox ~/repos/some-project
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
only affects the one `bin/claude-sandbox` invocation it's set for.

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
  `pre-push`, or set `core.hooksPath`), or write a
  `.claude/settings.local.json` with a malicious hook command, into the
  project. Both run unsandboxed on the host the next time you run `git`
  or open Claude Code in that repo - no network egress required, so the
  firewall doesn't see it either. Same underlying persistence pattern as
  the `~/.claude/hooks` and `~/.claude.json` risks above, just through the
  project mount instead of the config mount. "Only point this at trusted
  repositories" (above) covers input trust; this is about the sandbox
  writing a persistence payload into an otherwise-trusted repo.
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
- `settings.json`, `CLAUDE.md`, `plugins/`, and `hooks/` under `~/.claude`
  are layered back read-only on top of the (otherwise read-write) `~/.claude`
  mount. Hooks execute automatically with no separate approval step, so
  without this a compromised session could plant a backdoored hook -
  including by unlinking one of `install.sh`'s hook symlinks and dropping a
  plain file in its place, since the dynamic per-target mounts
  `bin/claude-sandbox` adds at launch only protect symlink targets that
  resolve *outside* `~/.claude`, never this directory itself - rewrite
  `CLAUDE.md` with injected instructions, or tamper with plugin code -
  something that would then run **unsandboxed on the host** the next time
  Claude Code starts there, turning a single compromised sandbox session
  into persistent host compromise. Everything else under `~/.claude`
  (session/project history, credentials refresh, caches) stays read-write,
  since it's runtime state Claude Code needs to update.
- `~/.claude.json` mixes that same kind of live state (project registry,
  usage stats, caches) with config (`mcpServers`). Unlike the four above,
  it can't just be layered read-only: Claude Code does an atomic
  write-temp-then-rename against it during normal startup, before login
  even completes, and a read-only file makes that **hang** instead of
  failing cleanly (confirmed against a real read-only copy of this file -
  upstream bug: [anthropics/claude-code#29162](https://github.com/anthropics/claude-code/issues/29162)).
  Instead, `bin/claude-sandbox` generates a throwaway copy of the file at
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
  claude-sandbox` warns if this looks like it might be happening - see
  below - but doesn't block it). The key source itself is mounted read-only
  at `/root/...`, not under the sandbox user's own home, specifically so
  that user (which the session actually runs as) has no path to read the
  raw key material - only the agent socket it's loaded into.
- The gitconfig copy `bin/claude-sandbox` generates (see that mount's
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
