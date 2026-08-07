# Configuration

[← dejima README](../README.md)

Day-to-day configuration once dejima is installed and running: what a
project declares versus what you approve, config parity with your host
Claude Code setup, a different editor, writable host directories, shared
scratch space, frontend testing, and what the sandbox knows about itself.

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

For a toolchain no package ecosystem ships in a version you can use - a
current Go, say, where Debian's is several releases behind - a dependency can
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
  again - which is the point, not friction to route around.

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
approval first - that is the part that grants - and report separately on the
declaration, so a project you can't write to still gets you the approval.
`--global` writes no declaration at all: there is no project to declare in.

The declaration those two write still grants nothing; it is the same
untrusted file the section above describes, and writing to it does not
promote it. That it is session-writable is exactly why both tools refuse to
write a `.dejima` directory or a `.dejima/<kind>` file that is a **symlink**:
a compromised session can plant one and then ask you to run the command that
follows it, which would aim a host-side append at your approval store or at
any other file you can write. The refusal is the `open` itself rather than a
test before it - `O_NOFOLLOW` on both, with the file opened relative to the
already-opened directory - so a session that is still running while you type
the command cannot swap `.dejima` or the declaration file out from under the
write. (Those two leaves are what the session controls. A symlink further up
a `--project` path you supply yourself is still resolved through.) Expect the
session to be live: the agent briefing tells the agent to ask you to run
`dejima-allow --project` from a terminal outside the sandbox. The same write
reads the file back to skip an already-declared entry, and that read is
capped - a session can make its own `.dejima/<kind>` arbitrarily large for
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
[Adding a domain to a running session](../README.md#adding-a-domain-to-a-running-session).
Approved dependencies are baked into a derived image built `FROM` the shared
base - first `dejima:<username>-global`, if the global store has any
dependency approved, then `dejima:<username>-<slug>` on top of that,
if the project store does - so they need an image rebuild: they take effect
on the **next** launch.

Because of that rebuild, the usual moment to approve is *after* leaving the
sandbox - so persistence (`--global` or `--project`) never requires a running
container.

`dejima-project approve` never attempts to patch a running session: it only
ever calls `dejima-allow` without `--container`, so recording the approval
is the only thing it does. If an individual approval can't be recorded - an
unwritable store, a slug collision, a corrupt approval list - it reports
that entry as not approved and keeps going, rather than stopping at the
first failure; that holds for dependencies and domains alike, so one bad
entry can't cost you the rest of the set. It then exits non-zero if anything
failed, so `dejima-project approve ~/myproject && dejima` won't launch a
session missing the approvals you just confirmed.

A session whose project declares something it doesn't have is told so in its
startup context, with the exact command to hand you. Project approvals are
inherited by subdirectories, so a git worktree under the project gets its
parent's; global approvals apply everywhere regardless.

## Config parity with your host Claude Code setup

Global `CLAUDE.md`, settings, hooks, skills, and plugins all carry over
automatically, and your existing login stays effective too - no separate
first-run login, though the credential itself never enters the container
(see [security notes](security.md) for the host-side proxy that makes
that work).

`~/.claude` itself is *not* shared as a whole: its contents are enumerated
in `docker-compose.yml`, config files are copied in rather than mounted,
and anything not listed is container-local - writable during the session,
gone with the container. Session transcripts, plans, and the edit-undo
record are on the list, so `claude --resume` on the host still works; a
credential, cache, or newly-added config file is not. The
[security notes](security.md) explain the split and why single-file
mounts couldn't be trusted here. (`~/.claude.json` is handled differently
again - a throwaway per-session copy, not the real file.)

The project directory is mounted at the *same absolute path* inside the
container as on the host, so Claude Code's session-history keying lines up
between host and container: a session's transcript is visible on the host
afterward, and `claude --resume <session-id>` should find it there. (Whether
a bare `claude --resume` with no ID picks it as the "most recent" session
depends on `~/.claude.json`'s own bookkeeping, which - per the throwaway-copy
design above - doesn't carry over from a sandboxed session.)

The container's own user matches yours exactly - username, uid, gid, and
home directory (see `Dockerfile`) - so `$HOME`-relative paths (dotfiles,
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
currently connected - it dies when that client disconnects, breaking
git-over-ssh for anything still running headless. For sandboxes meant to run
unattended, generate a dedicated, purpose-built keypair instead:

```sh
ssh-keygen -t ed25519 -N '' -f ~/.ssh/dejima_ed25519
```

Passphrase-less is deliberate - this is meant to be a low-privilege
credential living only inside the container, not your personal identity. Add
the public half as a Gitea deploy key scoped to just the repos that need
push access, then set it in the config:

```
[core]
ssh_key = ~/.ssh/dejima_ed25519
```

`entrypoint.sh` loads it into a container-local `ssh-agent` at startup and
deletes the plaintext copy immediately after - the sandbox user itself never
has a path to the raw key, only the agent socket (see
[security notes](security.md) for the full mount rationale). Setting
`[core] ssh_key` means a live forwarded agent is no longer required at all.

## Using a different editor/application

```sh
dejima --cmd nvim ~/repos/some-project
```

Runs unconfigured unless you also set `[mounts] nvim_config` in the config to
a real config directory on the host (bind-mounted read-only at
`~/.config/nvim` - lazy.nvim's lockfile is the one exception, layered
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

## Writable host directories

`[mounts] read_write` is the same thing without `:ro` - for a directory a
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

## Shared scratch space

`~/shared` is a read-write bind mount of `[core] share_dir` (default
`~/.local/share/dejima/shared`, created automatically) - separate
from the project mount, for passing files (screenshots, temp scripts) in and
out of a session without touching the actual checkout. Persists across
sessions since it's a real directory, not a container volume.

Treat it as a handoff point, not as general-purpose storage. If your own
project instructions tell agents to write somewhere at a fixed host path -
design docs, scratch notes, anything meant to outlive the session but stay out
of the project checkout - mount that directory instead, with
`[mounts] read_write`. It arrives at its own absolute path, so a convention
that says "put specs in `~/specs`" keeps working inside the container without
being rewritten to point at `~/shared`.

`~/shared`, the project mount, and anything in `[mounts] read_write` are the
only writable host paths in the container. Everything else a session writes
goes away with it.

## Testing frontend changes

Playwright (Chromium) is pre-installed at image build time, browser
included - `require("playwright")` works from any script, no network access
or per-project `npm install playwright` needed.

`localhost`/loopback traffic never goes through the egress firewall, so a
project's own dev server needs no firewall changes. A real external site
needs to be on the allowlist like any other network use
(`dejima-allow <domain>` for a running session, add
`--global`/`--project <path>` to persist it) - the firewall applies to the
browser's traffic exactly like `curl`/`git`.

If a project pins its own `playwright`/`@playwright/test` version, its
`npm install` may try to download a different Chromium build from
Playwright's CDN, which isn't allowlisted by default - allow it the same way
as any other one-off domain need.

Chromium's own process sandbox isn't actually active in this image (its
setuid helper isn't setuid here) - not a concern, since the container itself
is already the boundary that matters, and a compromised session already has
full shell access as the container's own user regardless.

## Sandbox self-awareness

### Project instructions: `.dejima.md`

`.dejima.md` at a project's root is that project's agent-instruction file -
the same role `CLAUDE.md` plays for Claude Code - under a name that doesn't
name a harness. dejima loads it into the session's opening context the way the
harness would load its own, so a project's instructions apply whichever agent
is running.

The reason for a second name: Claude Code finds a `CLAUDE.md` by itself, and
nothing else does. As dejima grows the ability to run agents that aren't Claude
Code, a project that wants to say "here is how to work on me" needs one file
that reaches all of them - so dejima delivers it rather than leaving each
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
disposable, firewalled container and should stay within the task at hand -
if something genuinely needs to break out (broader network, host changes,
GUI/hardware), stop and ask rather than trying to work around the firewall,
since the same session can be resumed unrestricted on the host via
`claude --resume`. No-op outside the container. `deny-dangerous-bash.sh`
(`PreToolUse`) also applies here, since `~/.claude/hooks` is mounted in.

`git-push-guard.sh` (`PreToolUse`/`Bash`, also `DEJIMA`-gated) blocks
any `git push` whose resolved remote isn't the Gitea host, and any push to
`main`/`master` even there. Like the other hooks, this is a fast-fail guard
against an overeager agent, not a hard security boundary - a session has full
shell access and could in principle edit `.git/config` to route around it.
GitHub push is blocked by default too (see
[GitHub push](../README.md#github-push-blocked-by-default-optional-opt-in) in
the README) unless `--allow-github-push` is given. For a real guarantee
against pushes to main/master, use branch protection on the remote itself.

`merge-guard.sh` (`PreToolUse`/`Bash`, `DEJIMA`-gated) blocks
`gitea-pr merge` inside the sandbox. It's the API-side counterpart to the rule
above: a merge puts a branch on `main` without ever performing a push, so
`git-push-guard.sh` never sees it. A hook is handed a command rather than a
conversation, so it can't tell an instructed merge from an unprompted one -
which is why it's scoped to the sandbox rather than applied everywhere. On the
host it does nothing, and you can still ask an agent to merge. The same
fast-fail caveat applies with more force than usual here: the session has the
Gitea token in its environment and could call the merge endpoint with `curl`
directly. Branch protection on the remote is the real guarantee.

`sandbox-context.sh` also tells the agent the actual workflow to follow: do
new work in a `git worktree` under the mounted project (e.g.
`.worktrees/<branch>`, never `../<branch>` or elsewhere under `$HOME` - only
the bind-mounted path is backed by real host storage, so a worktree created
outside it silently vanishes with the container), then push the feature
branch and run `gitea-pr create`.
