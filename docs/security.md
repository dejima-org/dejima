# Security notes

[← dejima README](../README.md)

**Threat model, honestly stated:** this reduces the blast radius of a
misbehaving or prompt-injected coding agent - it does not make it safe to
point at arbitrary untrusted or adversarial input, and it does not make
running an agent with its permission prompts off safe. Point it
at repositories you already trust. Everything below is about how bad a
compromised session *inside* that trust boundary can get, not a claim that
one can't happen.

**And none of it has been reviewed by anyone else.** This is early
development: the reasoning here is one person's, the tests assert what that
person thought to check, and no outside audit or adversarial testing has
happened. Read what follows as claims awaiting scrutiny rather than claims
that have survived it. See [SECURITY.md](../SECURITY.md).

## What dejima does not sandbox

Every item here is documented somewhere below, and a document organised by
control makes a reader assemble the negative space themselves. Most will not.
So it is collected here, at the top, where it is the first thing read rather
than the thing inferred from silence.

- **Exfiltration through a domain that is allowed.** The egress allowlist
  decides *where* a session may connect, not what it may put in the request. A
  session that can reach a host can encode data into a path or a query it
  sends there. Allowing a domain at all creates that channel.
- **Data encoded into DNS query names.** The DNS proxy answers for allowlisted
  domains; the names asked for are a channel of their own.
- **Anything below the container, where nothing is arranged there.** dejima's
  blast-radius table has rows beneath the container, and their controls belong
  to [dejima-devbox-hardener](https://gitbox.branderson.io/dejima/dejima-devbox-hardener).
  Run on a laptop with no VM layer, the row below the container is the
  operator's own machine, and dejima has nothing to say about it. See
  [Which deployment this describes](threat-model.md#which-deployment-this-describes).
- **Anything finer than a session.** The unit of isolation is one container for
  one session. An MCP server, a hook, or a tool the session runs inherits the
  session's whole reach - dejima reports that a session *added* an MCP server
  (see the audit surfaces below) and does not constrain what that server then
  does. Per-tool granularity would need a second sandbox inside this one.
- **Resource exhaustion.** No time limit, no memory limit, no CPU limit. A
  session that loops until someone notices is not prevented, and this is a
  deliberate omission rather than an oversight - see
  [Why there are no timeouts](#why-there-are-no-timeouts).
- **A suspended job. Ctrl-Z stops the observer, not the session.** It
  suspends `bin/dejima` on the host; the container keeps running, with its
  mounts, its firewall grants and its forge token, and keeps making requests
  while the terminal looks stopped. That is deliberate - SIGSTOP mid-tool-call
  leaves a session wherever it was, and the feature exists to get the terminal
  back rather than to pause the work - but a stopped job reads as a paused
  agent, and the difference matters most to whoever suspends one because they
  are uneasy about what it is doing.
- **The first layer's controls against an agent that has stopped
  cooperating.** The briefing and `.dejima.md` are advice. They shape what a
  cooperating agent does and stop nothing that has decided otherwise. Only the
  layers below them are enforcement.

## Why there are no timeouts

Every published checklist for sandboxing an agent lists timeouts alongside
non-root, egress filtering and read-only mounts. dejima has none, and the
reason is a judgement about what dejima is for rather than an item not yet
reached.

**A runaway session costs money and does not cross the boundary.** It burns
tokens and holds a CPU until someone looks. Nothing about it reaches the host,
widens the allowlist, or writes where a session may not write - the guarantees
dejima makes are all still held while it happens. A timeout would protect a
budget, which dejima has never claimed to protect.

**And "unattended" here does not mean "unobserved".** The sessions this is
built for run for days, and are checked at every issue and every pull request.
They need less babysitting, not none. A wall clock tuned for that is either so
long it prevents nothing or short enough to kill work in progress, and killing
a session mid-commit is a failure mode of its own.

If this changes it will be because a resource limit starts protecting the
boundary rather than the bill.

## Blast radius by layer

Where each layer's compromise stops, with and without the thing arranged
against it. The middle column is what the layer reaches if nothing is; the
last is what remains once something is.

| Layer | Reached by | Radius without | Bounded by | Radius with |
| --- | --- | --- | --- | --- |
| Agent, not yet hostile | ordinary operation | the workspace, its history, every mounted path, and the forge, at full speed | the session briefing and `.dejima.md`; the `PreToolUse` hooks | obvious destruction and out-of-remote pushes fail fast, and merging stays a human decision |
| Container | ordinary operation | the operator's home directory, every credential in it, and the open internet | dejima | the workspace, allowlisted domains, and the forge token's scope |
| Devbox VM, unprivileged | container escape | everything the account can read, and unrestricted egress to the internet and the LAN | `dejima-devbox-hardener` | the same VM, with LAN reach cut to what is declared; internet egress stays open, deliberately |
| Devbox VM, root | escape plus local escalation, or misconfiguration | the whole VM, the same egress, and the model API credential | `dejima-devbox-hardener`, enforced outside the guest | the whole VM and no further: root cannot reach the rule set that holds the LAN boundary |
| CI, confined job | a session opening a pull request | code execution on the runner, its network position, and the token the forge injects into every job | `dejima-ci-hardener`, confined tier | the allowlist, and nothing else on the LAN |
| CI, confined job escaped | an escape from a confined job | root on the runner VM | the hypervisor firewall and a scheduled rollback | the privileged tier's position: the allowlist is gone, the LAN is not, and the loss expires |
| CI, privileged job | `runs-on:` asking for it | root on the runner VM, by design and without any exploit | the same two controls, both external to the VM | the VM and its network position, until the next rebuild |

Only the first row's control is advice: hooks and context tell an agent what
not to do, and one that has stopped cooperating ignores them. Only the first
two rows are dejima's own. The rest is why there are two sister repositories,
and this table is the short form of
**→ [threat-model.md](threat-model.md)**, which has the assumptions, the
adversaries, and what none of this claims.

## CI: push access is code execution elsewhere

The controls in this document bound what a session can reach *directly*. They
do not bound what it can arrange to have run somewhere else, and if the
project has CI, **granting a session push access grants it code execution on
whatever host that CI runs on.** No operator action is needed anywhere in the
chain: the push guard permits a feature branch, the briefing tells the agent
to open a pull request without asking, `on: pull_request` fires, and the
runner checks out that commit and executes it. The you-merge-not-the-agent
gate sits strictly downstream: by the time anyone reads the diff, it has
already run.

Nor does the code have to be a modified workflow file. A workflow that runs a
test suite runs every file in it, so a plausible-looking helper in a test file
is executed just as surely, and far more quietly, than an edited workflow
would be.

Relative to the sandbox, a run adds three things: **execution on a host you
own**, outside the container and outside the allowlist; **egress from a
network position you own**, with no firewall and no DNS proxy in front of it;
and **whatever credentials the run is handed**, including the token the forge
injects into every job whether the workflow asks for one or not.

There is deliberately no approval gate offered for this. Every version of one
(changing the trigger, dispatching by hand, leaving the runner stopped, the
forge's own fork-PR approvals, filtering egress from inside the workflow) is
reachable from the branch, covered by a credential the session already holds,
or not a gate at all. The mitigations are environmental instead: a runner host
you are willing to lose, job containers with no Docker socket, deny-by-default
egress whose allowlist is read from `main` rather than from the branch, and no
secret a run does not need. And where none of that is available, declining the
push grant declines the code execution with it: `[core] forge = none` with
`[core] workflow = local-only`.

This applies to any project developed in a dejima sandbox, not only to this
repository. **→ [docs/ci.md](ci.md)** for the reasoning and the setup.

## To your forge, the sandbox is you

By default a session authenticates with your credentials: your SSH key through
the forwarded agent, and a token generated under your account. A push, a pull
request, a comment or a merge made from inside the sandbox is therefore
**indistinguishable at the forge from one you made yourself**, not similar to
it, identical.

The consequence is worth stating flatly, because it is easy to configure
around without noticing: **every control your forge offers that keys on
identity is a guard rather than a boundary.** Branch protection's merge
whitelist, its push whitelist, required approvals, and the audit log all
answer the question "who did this", and there is only one answer available.
Putting yourself on a merge whitelist puts the sandbox on it too.

Three specific consequences:

- **Required approvals are not merely weak here, they are unusable.** A forge
  will not let a pull request's author approve it, and the sandbox opens pull
  requests as you, so requiring one approval means nobody can give it.
- **The forge's audit trail cannot attribute.** "You pushed this" and "a
  session pushed this" are the same recorded event. This is the same shape as
  the exit-time audit's time-window caveat below: a record of what happened,
  not of who caused it.
- **It compounds the SSH agent's reach.** The agent already signs for any repo
  your key can reach (below); the identity is what makes the resulting action
  land as yours everywhere it reaches.

### Give the sandbox its own identity

This is configuration, not a missing feature. Create a dedicated forge account
with **write** access to the repositories a session should work on, and point
the sandbox at it instead of at you:

- `[forge.gitea] token_file`: that account's token, rather than one issued
  under yours.
- `[core] ssh_key`: a deploy key belonging to it, rather than your forwarded
  agent. See "Headless git push without agent forwarding" in
  [docs/configuration.md](configuration.md).

With the two identities separated, the same settings stop being decorative:

| Setting | What it becomes |
| --- | --- |
| Merge whitelist: you | The session genuinely cannot merge |
| Push whitelist on `main`: you, or nobody | The session pushes feature branches and nothing else |
| Require approvals ≥ 1 | Usable: the session authors, you approve |

That last row is the one that turns "the operator merges, the agent does not"
from a convention into something the forge enforces.

**Verify which credential a push actually uses.** Nothing here enforces one:
`[core] ssh_key` is a second, independent credential path (below), so if your
own agent is *also* forwarded, a push may still be signed by your personal
key and the separate identity becomes decorative for exactly the operation it
was meant to constrain. Make a test push and read what the forge attributes
it to, rather than assuming.

**Write access, and specifically not ownership.** Add the account as a
collaborator on the repositories it works on. Write is the ceiling here, not
a floor: an account that owns a repository, or holds admin on it, can merge
its own work and edit the settings in the table above, so every row of that
table goes back to being decorative. `write:repository` and `write:issue` are
the scopes its token needs (README, "Gitea/Forgejo PR workflow"), and nothing
about that changes for a collaborator.

One consequence presents as a misconfiguration, and the obvious fix is the
wrong one. Parts of Gitea's API are gated on *ownership* rather than on
permission: `GET
/repos/{owner}/{repo}/actions/runs` answers a non-owner with `"user should be
the owner of the repo"` no matter which scopes the token carries. Read that
way it looks like a scope error, and the reflex is to widen the token. That
cannot work, since no scope grants ownership, and its only real remedy is
handing the sandbox your own token, which would undo this whole section.

`gitea-actions` therefore reads CI through `actions/tasks`, the commit's
statuses and the run view's log route, none of which are owner-gated. If some
future need lands on an owner-only endpoint, leaving that capability
unavailable is the better trade than promoting the account.

Two things a separate identity does **not** do:

- It does not reduce what a compromised session can do inside the container,
  or to the mounted project. It changes what that session can do *to your
  forge*, and who the forge thinks did it.
- It does not touch CI. A write-capable account can still push a feature
  branch, and pushing a branch is what makes CI execute code; see the
  section above. It also has no bearing on the token the forge injects into a
  CI job, which is a third principal again, subject to none of the settings in
  that table. **→ [docs/ci.md](ci.md)**

## Provider trust

Forges, workflows and harnesses (`forges/`, `workflows/`, `harnesses/`) are
**data**, never sourced or executed. A provider's manifest is parsed with
the same discipline as the main config file - an unknown key or a bad value
is a hard error, not a silent pass-through - and its optional briefing
prose is substituted into and handed to the agent, never interpreted as
code. `bin/dejima` resolves the selected forge/workflow/harness **on the
host** and passes only the resolved results into the container - which
hosts pushes are allowed to, which branches are protected, the literal merge
command to block, plus the forge's own environment variables (a Gitea API
token for `gitea`, a write-capable PAT for `github`, nothing for `none`) -
never a manifest or a provider
directory itself. The one thing a provider ships that does run is a forge's
`bin/`, copied into the image at build time as an ordinary program on
`PATH`, no different from any other CLI baked into it.

The session briefing text (what `hooks/sandbox-context.sh` injects at
`SessionStart`) is composed the same way: **host-side**, from a fixed core
fragment no provider can override plus the selected workflow's and
harness's own prose, then mounted **read-only** into the container - so a
compromised session cannot rewrite what it is *currently* being told. That
guarantee does not reach into the *next* session: a workflow's or harness's
briefing fragment (e.g. `workflows/worktree-pr/briefing.md`) lives in the
checkout itself and needs no symlink to edit, so a session with write access
to this repo's own checkout can change what the next launch composes and
hands to whichever session starts against it.

**Which requires dejima's own checkout to be the workspace, and almost never
is.** Nothing mounts `forges/`, `workflows/`, `harnesses/`, `tools/` or the
rest of the checkout into a container - the resolved values go in, the files
do not - so for every launch pointed at some other project, a session cannot
read these paths, let alone write them. The rest of this section is about the
one configuration where it can: dejima sandboxing the repository it is itself
installed from, which is how dejima is developed. `bin/dejima` says so at
launch when it notices.

In that configuration the provider directories are in the exit-time audit's
TCB list, alongside `bin/`, `hooks/`, `docker/`, `test/` and `tools/`. They
hold no code and nothing executes them, but what they hold decides what the
next launch permits: a forge's `fixed_hosts` reaches `DEJIMA_FORGE_HOSTS`,
which `firewall-up.sh` joins into the permitted set the egress policy is given, so
a line added to a manifest widens the egress boundary on the next run.
`tools/*/tool.conf` is the same class, and is read by the host rather than the
container: it names a tarball URL, the sha256 checked against it and the
layout it is unpacked with, all consumed by the image build - so a session
that edits one chooses what the next launch downloads and installs as root.
`backends/*/backend.conf` names the upstream every request is forwarded to and
the host path the credential is read from, so an edit there redirects where a
real credential is sent.

An ordinary edit is a diff you are about to read and is not reported; one git
cannot see - hidden by `.gitignore`, `.git/info/exclude`, `assume-unchanged`
or `skip-worktree` - is a CRITICAL finding. It is still a change a session
can make; it is one the audit reports. See
[docs/providers.md](providers.md) for the full manifest contract.

## The mounted project is fully writable

- Running the harness with its permission prompts off removes your chance to
  review tool calls before they run. Only point this at trusted repositories.
- The mounted project itself has **no write protection**. The guards are
  fast-fail checks against an overeager agent doing something obviously
  destructive, not a boundary against one actively trying to get around them.
  `deny-dangerous-bash.sh` is regex pattern-matching on the literal Bash
  command string, so a different scripting language, an encoded command or
  editing `.git/config` directly all sail right through. The push and merge
  guards shadow `git` and the forge CLI on `PATH` and read argv, so quoting
  and pipelines stop mattering - but a session that means to get round one can
  call `/usr/bin/git` directly. Nothing here stops a compromised or
  badly-instructed session from modifying or deleting the real working copy
  it's mounted against.
- That same read-write access to the mounted project is also a
  host-code-execution vector, not just a data-destruction one: a
  compromised session could plant `.git/hooks/post-commit` (or
  `pre-push`), set `core.hooksPath`, or write a
  `.claude/settings.local.json` with a malicious hook command, into the
  project. Any of those run unsandboxed on the host the next time you run
  `git` or open your harness in that repo - no network egress required, so
  the firewall doesn't see it either. Same underlying persistence pattern
  as the harness config risks above, just through
  the project mount instead of the config mount. "Only point this at
  trusted repositories" (above) covers input trust; this is about the
  sandbox writing a persistence payload into an otherwise-trusted repo.
  The workspace's own `.git/hooks` directory is mounted read-only
  (same pattern as the harness's own code directories below), so planting a hook
  file directly is closed - accepted breakage: installing hooks
  *in-session* (`husky`, `pre-commit install`) fails, which is the
  point. `core.hooksPath` and `.claude/settings.local.json` aren't
  overlaid (they're config, not fixed paths a static mount can cover) and
  remain fully writable; the exit-time audit below reports changes to
  either, but only after the session ends - it doesn't stop them.
## The exit-time audit

`bin/dejima-audit` snapshots host-persistence surfaces before each run and
diffs them after the container exits. It is **advisory**: it fires after the
session ended, so a planted `core.hooksPath` is something to clean up before
the next `git` or `claude` in that repo, not something that was blocked. It is
silent when nothing changed and never affects the session's exit code.

**Its diff is time-windowed, not session-attributed:** a finding means a path
changed while the session ran, not that the session changed it. A concurrent
session, another host process, or your own editing all land in the same diff,
reported identically.

### What it watches

`.git/config` (and worktree `config.worktree`) keys that run a command on the
next `git` - `core.hooksPath`, `core.fsmonitor`, `core.sshCommand`,
`credential.helper`, `core.pager`, `pager.*`, `core.editor`, `sequence.editor`,
`gpg.program`, `diff.external`, `merge.*.driver`, `diff.*.command`,
`filter.*.smudge`/`clean`/`process`, `diff.*.textconv`,
`include.path`/`includeif.*.path` (config indirection - these can point at a
planted file that itself sets an exec key, so the exec key never appears in
`.git/config` directly), `!`-shell aliases - plus content changes under the
workspace's `.claude/`, `.mcp.json`, `.envrc`, `.vscode/`, and `.git/hooks/`
(symlinks included - a repointed symlink is hashed by its target, not just its
content). When the mounted workspace is this repo itself, it also hashes the
sandbox's own trusted computing base: `bin/`, `hooks/`, `docker/`,
`install.sh`, `test/`.

Coverage is a fixed list rather than a general integrity check, so a config
surface it has not been taught about goes unreported. It does not cover
`[core] share_dir` (see
[Shared scratch space](configuration.md#shared-scratch-space)).

**A git worktree isolates the working tree, not `.git/config`.** Config is
shared with the parent checkout, so a bare `git config <key> <value>` inside a
worktree writes the real repository's config, including any exec key above. The
briefing says so, and gives `git -C <path> config`. That is a guard against an
unaware agent, not a boundary: `.git/config` is in the read-write project mount
and cannot be read-only without breaking `git push -u`, which writes
`branch.<name>.merge` on every push. Detection covers the rest, and did - this
was found by the audit reporting a `.git/config` change.

### Approving and ignoring are different decisions

The difference is what you are promising about next time. Approving records the
exact content (`safe <id> <sha>`), so this file with these bytes is fine and any
other content re-fires. Ignoring records the surface (`spam <id>`), so this path
or key is fine whatever it later contains. Approve a hook you have read; ignore
a key some tool rewrites on every run and which you have decided you will never
care about. The review offers both, and says which is which:

```
[a] approve this exact content  [i] ignore this key from now on  [s] skip (ask again next time)  [q] quit
```

Skipping asks again next session, the right default when you are unsure. It
matters for keys some tools rewrite on every run: with no decision recorded, one
re-fires every session and pushes real findings out of the capped list.

A report walked to the end stops being counted as waiting, but stays on disk as
the record of what that session did. `[audit] keep` decides how many are
retained; rotation evicts one, `ack` never does.

A finding whose file has since been deleted is **cleared** rather than approved:
there is no content left to pin an approval to, and a surface that does not
exist does not run. Nothing is recorded, so if it comes back it comes back as a
new finding. Refusing would leave the report unresolvable, since `ack` opens
CRITICAL reports first.

Severity is not negotiable by either verb. An exec-capable key or shell alias is
CRITICAL whatever the baseline says, and an `ignore` entry is refused against a
CRITICAL surface when the baseline is read, not only when written - so neither
decision can quietly downgrade something that matters.

### What `ack` shows you

For a surface that changed during the session it prints a unified diff of the
pre-session content against the current content; for one created during the
session it prints the whole current content. To make that possible, `snapshot`
stages a copy of each monitored surface's bytes for the duration of the session,
and `compare` turns those into **bounded diffs** in a `<report>.d/` directory
beside the report. What persists afterwards is only the diff of a *modified*
surface, never a whole file. A created surface stores a marker (its content is
live on disk); a removed one stores nothing, because a deletion diff *is* the
whole former file.

What it prints is chosen by what changed, which is not always what you need in
order to judge it: three changed lines in a hook script are only judgeable by
reading the script. `[o]` at the prompt opens the file in `$VISUAL`/`$EDITOR`,
read-only where the editor understands how, and returns to the same decision. It
opens the file **as it is now**, for the same reason an approval pins the content
on disk at the moment it is recorded: approving something nobody read would be
the one outcome worse than not asking.

Staging and retained diffs live under `$AUDIT_DIR`
(`~/.local/share/dejima/audit`), never `/tmp`. That is the boundary the scheme
rests on: nothing in `docker-compose.yml` covers it, so the container cannot read
earlier runs' retained content, and `static.bats` pins that. A store configured
*inside* the workspace is readable and deletable from the sandbox, so nothing is
retained in that case, only a note saying why.

A `SIGKILL`ed session runs no EXIT trap and leaves its staging directory; the
next run against that workspace reaps it, identifying dead owners by pid and
process start time from an `.owner` file so a concurrent session is never
mistaken for dead. A missing or unreadable owner record falls back to a 24-hour
age check rather than guessing.

### When content is withheld from the store

In every case below `ack` prints the reason in place of the diff - so an absent
diff is never mistaken for an absent change - and still shows the live current
content on your terminal, because withholding is about the persistent store, not
about what you are shown while deciding.

Surfaces that hold credentials by convention are never staged in the first
place, so their bytes are never even copied transiently: `.envrc`, `.mcp.json`
and `.claude/settings.local.json` by exact path, and `.env`/`.env.*` by
*basename*, at any depth - so a nested `.claude/.env` is caught too.

A surface that existed before the session but was too large to have been staged
(over 1 MiB) withholds with "no pre-session copy", not a false claim that it is
new. The *current* side is bounded by that same cap, and checked *before* any
copy is taken: a file the session grew past it withholds with "change too large
to retain" rather than being copied through `$TMPDIR` first. The ordering is the
point, not the cap. `compare` runs from the exit trap on every exit and the size
is the session's own choice, so copying first would turn "I filled my own
workspace" into that many bytes written to `$TMPDIR` - often a tmpfs, so host
RAM - and into a whole copy left there if the exit was a `SIGKILL`.

A generated diff is withheld if it is binary, over 200 lines or 64 KiB (bounded
as it is generated, for the same reason), or matches a best-effort credential
screen: vendor prefixes including `sk-ant-`, `sk-proj-`, `ghp_`, `gho_`,
`github_pat_`, `glpat-`, Slack's `xox[baprs]-`, `AIza`, `AKIA`, `_authToken`,
`Authorization: Bearer`, and PEM private-key headers, matched case-insensitively
since `.claude/settings.json`'s `env` block - the one high-value surface this is
the only net for - conventionally holds its keys upper-case. The screen has real
false negatives; the denylist is the reliable half.

A git config key with more than one value on either side is not compared. Git
resolves such a key to its last value in FILE order; the audit parses and sorts,
so lexicographically-last is not what git runs, and the pre-session side is every
value the key had. Comparing anyway produced a diff over values git does not use:
two pre-session values read as a deletion that never happened, while the appended
value git now executes appeared nowhere. It withholds instead, and must be
compared by hand. `include.path` is legitimately multi-valued, so this is an
ordinary shape.

A diff can also come out empty when the config file's TEXT changed but the parsed
value did not, e.g. a re-quoted value. That withholds too, saying so rather than
showing nothing, since an empty diff for a reported change reads as a bug.

A per-report **retention budget** (`RETAIN_BUDGET`, 1 MiB) bounds the total diff
bytes one report keeps. Once spent, the rest withhold and both the report and the
stderr summary add an alarm line: that many changed host-persistence surfaces in
one session is a signal in itself, not a limit worth raising. `diffs = off` in
`[audit]` disables retention and staging.

Two residual limits on top of the screen's false negatives. The prompt truncates
at 40 lines, naming the file so you can read the rest, so a large planted change
is cut exactly where you would want it whole. And the `SIGKILL` case is an
exposure window, not just a cleanup mechanic: until the next run reaps it, the
staging directory holds whole pre-session file copies of every monitored surface,
for as long as the workspace goes unused.

### Findings reach your terminal as untrusted text

They name a path or config key the session may have chosen. One containing an
ASCII or C1 control or a Unicode bidi override - which can scroll, blank or
reorder what you read, and split a name across the audit's own records - is
written hex-encoded behind a `{hex}` marker and decodes with
`printf '%b' "$(sed 's/../\\x&/g' <<< HEX)"`. Ordinary names print as-is, so
the marker appearing is itself worth a look. The encoded form is what `ack`
records, so what you acknowledge is the file on disk rather than a readable
approximation of its name.

## One project's session cannot reach another's

The property is the same for every harness; the mechanism is not, because it
depends on how the harness keys its own state. Claude Code stores a directory
per project and dejima mounts a slice of it. Cline stores one flat database
indexing every session it has ever run, with the project as a field inside the
record, so there is no slice to take - dejima gives each workspace a data
directory of its own instead. Both reach the same place: a session sees its
own project's history and no other's.

### Claude Code: a slice of your own tree

- `~/.claude/projects` (session transcripts and per-project memory) is
  **not** mounted as a tree. A session gets the workspace's own slug
  directory plus one for each live git worktree nested under it,
  read-write, and nothing else. Every other project's slug is *absent*
  from the container rather than present-but-unwritable. Agent memory is
  loaded into context at session start, so a write into another project's
  `memory/` is text a future session there reads as established background
  rather than as input - and until #104 the mount alone was enough to do
  that, with no escape and no credential involved.

  The set is derived from real worktree paths
  (`bin/dejima-slug-lib.sh`), not from the slug string, because a slug
  cannot tell a child from a sibling: `/w/proj/wt1` and `/w/proj-wt1`
  produce the same one. A `<slug>-*` glob therefore also matches any
  project checked out beside this one whose directory name merely extends
  it, which is an ordinary layout rather than a contrived one.

  `projects/` itself stays container-local, so a slug that is not mounted
  is still writable during the session and just does not survive it. That
  is what lets Claude Code create a slug it does not find, which is the
  first-run case it already handles, and it is why an absent sibling does
  not risk the hang that a blocked write to `~/.claude.json` caused.

  Residual: the workspace's own transcripts and memory stay fully writable
  throughout, since Claude Code needs that for host-side `claude --resume`.

  There is deliberately no `CROSS-PROJECT` finding. Since #104 a session
  gets its own slugs and nothing else, so the only writes the audit could see
  there are other sessions doing their own work - and on a host running
  several at once it would report all of them, on every report. Detection
  that cannot observe what it exists for, and fires constantly on what it
  does not, trains an operator to skim. The mount is the control, and
  `static.bats` pins it.
- `~/.claude/file-history` (Claude Code's edit-undo record) is **not**
  mounted as a tree either, and the reason is sharper than for `projects/`.
  Each `<session>/<hash>@v1` is a **verbatim copy of an edited file**, so the
  tree is other projects' source rather than a record about it. Read access
  alone is the leak; it was read-write on top of that, and tampering with
  another project's undo record puts chosen content into a later restore.

  It is keyed by session id, so unlike `projects/` there is no slug in its
  own paths to scope it by. The transcript names supply it: `projects/<slug>/
  <id>.jsonl` and `file-history/<id>` name the same session, so the slugs the
  workspace owns select the session ids it owns
  (`workspace_session_ids` in `bin/dejima-slug-lib.sh`). A directory whose
  session has no transcript belongs to no project dejima can identify, and is
  left out.

  The session about to start has an id nothing can know in advance, so its
  own directory is created container-local and does not survive the run.
  That costs undo history for that session if it is later resumed on the
  host, and it is the reason this cannot be scoped as completely as
  `projects/`, where the workspace's own slug is known at launch.

### Cline: a directory dejima owns, one per workspace

- `~/.cline/data` is **not** mounted. Cline indexes every session it has ever
  run in one `sessions.db`, with the project a session belonged to as a field
  inside the record rather than a directory above it, so there is no
  per-project subtree to slice: mounting your data directory would put every
  project's transcripts in every session, which is this section's whole
  subject.

  A launch instead creates `<[harness.cline] state_dir>/<workspace slug>` on
  the host and mounts *that* at `~/.cline/data`. Every session under it belongs
  to this project by construction rather than by a filter that could be wrong,
  which is why Cline clears this requirement more cleanly than Claude Code
  rather than less.

  The cost is that the directory is dejima's rather than yours: a session
  started inside the sandbox is not offered back to a host-side Cline, and one
  you started on the host is not visible inside. There is no import or export
  ([#301](https://gitbox.branderson.io/dejima/dejima/issues/301)), and the
  briefing tells the session so, so it will not offer you a resume command that
  cannot work.

### Whichever harness is selected

- Epitaphs - the summary a session leaves when its context is compacted away -
  are kept host-side in `[epitaph] dir`, and that directory is never mounted. A session can neither read what earlier
  sessions concluded nor edit what this one is about to record, which is the
  same arrangement as the audit store and for the same reason. The transcript
  they are extracted from *is* session-writable, so a summary records what was
  there rather than vouching for it - and nothing loads one back into a later
  session, deliberately: that would be the channel #104 closed, rebuilt.
- `[core] share_dir` is **not** mounted whole. A launch mounts
  `<share_dir>/projects/<slug>` at `~/shared`, so a session sees its own
  project's handoff files and no other project's - the same slicing as
  `projects/` above, applied to the directory that was the remaining way
  around it. A handoff file is session-authored by design, and one project's
  session writing a plausible-looking note that a session in another project
  then picks up is #104's channel by a different route.

  The per-project split bounds *which* sessions, not *how long*: a project's
  share persists, so everything in it is readable by every later session
  against that project. Nothing prunes it, which is why
  [docs/configuration.md](configuration.md#shared-scratch-space) says to clear
  it out and `dejima-share list` prints what each project is holding.

  `<share_dir>/projects` is in the guarded list, so an operator cannot hand
  the whole of it back through `[mounts] readonly` or `[mounts] read_write`.
  The session's own share arrives at `~/shared` without going through either.
## The model API credential never enters the container

### Four arrangements, and what a session can take from each

Which one a launch is in comes from the selected backend's `credential` kind
and from whether the proxy is on. The differences are worth stating together,
because only the last one puts a durable credential where a session can read
it.

| Arrangement | In the container | What a compromised session can take | What it can still do |
| --- | --- | --- | --- |
| **Proxied, refreshing** (`credential = anthropic-oauth`) | A fake credential file whose secrets are placeholders. The real one is read host-side per request. | The placeholder. | Use the API as you, through the proxy, while the session runs. |
| **Proxied, static key** (`credential = static`) | A placeholder key in the harness's own model configuration, and the endpoint's real hostname. | The placeholder. | The same. |
| **A backend with no credential** (`credential = none`, a model you serve) | Nothing but the endpoint's address. It needs no credential, so there is none to withhold. | Nothing. | Reach that endpoint, which is why it has to be one you allowlisted. |
| **No proxy** (`[credentials] proxy = off`, or `[backend.<name>] proxy = off`) | The real credential file, mounted. | **The credential itself**, durable and usable offline. | Everything the credential allows, for as long as it is valid. |

**The first three keep the credential out; the fourth does not.** That is the
whole of the difference, and it is why `proxy = off` is described here as a
kill switch rather than as an option.

**Both Anthropic billing models are in the first three.** A subscription login
is `backends/anthropic`, whose OAuth token the proxy refreshes and writes back;
a console key is `backends/anthropic-api-key`, a static credential against the
same endpoint presented as `x-api-key` - one backend whether the key came from
Claude Code's own login or a file you hold. Either way the credential is held on
the host and injected per request. On the API-key path the container gets
`ANTHROPIC_API_KEY=sandbox-credential-proxy-placeholder` and no credential file
at all.

**Only `proxy = off` lands in the fourth row, and only where you wrote it.**
A credential the selected backend cannot serve - a Claude Code signed in with
a console API token, whose file holds no `claudeAiOauth` block, against
`backends/anthropic` - is a refusal, naming the backend, the file, the shape
it expected and the two ways forward. A kill switch that can engage itself is
not one, which is why this row is a kill switch rather than an option.

The refusal is scoped to a credential that *exists* and cannot be served. An
absent one mounts nothing and downgrades nothing - that is a host where the
harness has not been signed in yet, and it still launches.

**The proxy is switched per backend, not globally.** `[backend.<name>] proxy`
falls back to `[credentials] proxy` when unset. One backend whose credential
the proxy cannot serve is then an opt-out for that backend, rather than a
reason to stop withholding credentials from the ones it serves. Turning it off
for a backend prints what the session is being given, because it is a
downgrade the operator chose rather than a setting that happens to be off.

**Everything dejima copies in is scanned for credential-shaped values it does
not recognise, and an unknown one is a question rather than a surprise.** The
scanner reports a redacted path, a shape name, the harness and the backend -
never the value, and never a real path, since a gitconfig can carry userinfo
in a section header. **Finding it is best effort**: this recognises common
credential shapes and can miss an unusual one. Removing one it has found is
not - a value it names is removed whole, including one split across
continuation lines.

The choice is yours: keep it out for this launch, let it in for this launch,
let it in every launch, or stop. Only the third persists, in
`credential-scan.decisions` beside your config, keyed by field rather than by
value so rotating a credential does not re-ask a question you already
answered. A standing *scrub* is available there too but is not offered at the
prompt: removing something the harness turns out to need would break every
launch after, with the cause several layers from the symptom. With nothing
attached to answer, the launch stops rather than carrying it in.

This is the general form of the two fixes below, which are denylists and so
only know what was already found. See
[#291](https://gitbox.branderson.io/dejima/dejima/issues/291).

#### What the scan does not catch

It recognises the *shape* of a credential, not its meaning, so it is a
backstop against the class of leak that has actually happened here twice -
not a guarantee that nothing crosses. Specifically:

- **Values containing whitespace.** Both heuristic rules require one token
  from a restricted alphabet, because the alternative flags every sentence in
  a config file: English prose scores 4.0-4.5 bits per character by the same
  entropy measure a random key does. People do put spaces in passphrases they
  chose themselves, and one of those would go straight through. It is a
  deliberate trade and it fits these files, which hold credentials issued to a
  machine rather than typed by a person.
- **Short or low-entropy secrets in fields not named like one.** A token that
  is eight lowercase letters in a field called `nickname` is indistinguishable
  from a nickname.
- **Anything in a format it cannot parse.** JSON and INI only. An unparseable
  file is copied unchecked, and says so at launch rather than being silently
  trusted or silently blocked.
- **Anything dejima does not copy.** This covers the files dejima *stages* -
  `~/.claude.json` and `~/.gitconfig`. It does not read your read-write
  mounts, the workspace, or anything else you have pointed a session at, and a
  credential you leave in one of those is not something dejima is looking for.

The value of it is not that it is exhaustive. It is that a credential shape
dejima has never seen becomes a question at launch instead of a copy nobody
noticed for a year.

**Two host files are copied into a container, and both are filtered.**
`~/.gitconfig` can hold a `credential.helper` that prints a token, an
`http.<url>.extraHeader` carrying an Authorization line, or userinfo inside a
`url.<...>.insteadOf` key; none of that is part of what the sandbox is
granted, so the copy drops it and says so. The general problem - that these
filters are denylists, and a harness's authentication is not a stable
interface - is [#291](https://gitbox.branderson.io/dejima/dejima/issues/291).

**`~/.claude.json` is staged, not mounted, and the staging strips a
credential.** That file mixes app state with configuration the copy exists to
carry, and a Claude Code signed in with a console API token keeps its key
there as a top-level `primaryApiKey` - not in `.credentials.json`, which stays
`{}` for that login. The copy drops that key, and `backends/anthropic-api-key`
reads it host-side per request instead. Without it the proxy would
withhold one file while dejima copied another, on every launch and whatever
backend was selected.

**The residual the first two share is use-while-running.** A session that has
been turned can spend your quota, ask the model anything, and read the answers
- through the proxy, without ever holding the credential. That is inherent to
the sandbox working at all: the session has to be able to reach the model, and
anything it can reach it can misuse. What the proxy buys is that the misuse
stops when the session does, and nothing durable leaves.

**Refreshing and static differ in what a leak elsewhere costs, not in what the
container sees.** Neither enters it. But an OAuth access token is short-lived
and the proxy rotates it, while an API key is typically long-lived and
account-wide - so the host-side file is worth more in the static case, and a
compromise of the *host* is correspondingly worse. Scope the key at the
backend where you can, the same argument
[docs/providers.md](providers.md) makes for a repository-scoped forge token.

**The proxied domain is not in the egress allowlist while the proxy is on.**
`docker/fixed-domains.sh` adds it only when there is no proxy, so a session
that tries to reach the API by name finds it unresolvable and goes through the
terminator instead. Worth being precise about the limit: this defeats a lookup,
not a route. The API's address stays reachable as an IP literal for as long as
any other allowlisted name resolves to it.

**A hosted OpenAI-compatible backend is the second arrangement, and it is
what `backends/openrouter` is.** The key sits in a file on the host, named by
`[backend.openrouter] credential_file` and read per request; the container
gets `sandbox-credential-proxy-placeholder` and the endpoint's real hostname,
which the in-container terminator answers for. Nothing about the arrangement
is visible to the session, which is the same property the Anthropic path has
and the reason both are worth having rather than one.

Worth naming what a *hosted* backend adds over Anthropic's OAuth, since it is
not the container that changes: an API key is typically long-lived and
account-wide where an access token is short-lived and rotated, so the host-side
file is worth more. Scope the key at the backend where it offers that, the
same argument this repository makes for a repository-scoped forge token.

**A backend you serve yourself is the strongest posture available**, and it is
worth saying so plainly rather than treating it as the degraded one. A session
pointed at a model on your own network has no credential anywhere in the
picture, so there is nothing to place, nothing to withhold and nothing to
steal. What it costs is that the model is yours to run.

It is a backend like any other - `backends/self-hosted`, with
`credential = none` and its address in `[backend.self-hosted] base_url`. That
placement is deliberate: an operator who serves a model locally and also uses a
hosted API keeps both configured and switches by changing one word, rather than
having to unset one setting to stop it overriding another.

**This assumes the host has one.** dejima authenticates nothing: the proxy
holds a credential the harness wrote on the host, so a machine where the
harness has never signed in has nothing for it to hold. The proxy then does
not start, no credential is mounted, and the session comes up unable to
reach the model - which reads as a dejima fault rather than a missing
prerequisite. Sign in on the host first; see the README's
[Sign in on the host first](../README.md#sign-in-on-the-host-first).
Refreshing an expired credential is the same: on the host, not from inside a
session, where the credential deliberately never goes. A session that outlives
its credential - one left open overnight is the ordinary way - meets a 502 from
the proxy naming that as the remedy, and the same line is the last thing the
proxy logs, so the exit audit repeats it on the host terminal.

**What the proxy may tell a session about a credential failure.** Anything it
learned from the provider stays on the host: a response body, a status line, an
exception. What crosses into the container is text this repository wrote, and
only when it names something the operator has to do - "log in again on the
host" is useful to an agent that would otherwise report itself broken, and
discloses nothing the session did not already know. The distinction is the
credential proxy's `CredentialNeedsOperator`, which carries the two separately
so neither can be sent by accident.

### The refreshing OAuth path, in detail

The `backends/anthropic` arrangement, at the level of what the proxy actually
does. The machinery is not Anthropic's - the credential's kind, which header
carries it, what must not travel beside it are all arguments a backend
supplies - but it is worth reading through one backend rather than in the
abstract, and this is the one with the most miles on it.

- The Anthropic OAuth credential (`~/.claude/.credentials.json`) never
  enters the container. It isn't mounted: `~/.claude` is not shared as a
  whole (see the mount inventory below), so there is no path from
  inside the container to that file. `dejima` starts a host-side proxy
  (`bin/dejima-credential-proxy`) on a per-session unix socket and mounts a
  fake credential in place of the real one - the secrets are placeholders,
  while `scopes`/`subscriptionType`/`rateLimitTier`/`clientId` are copied so
  the session's UI stays accurate. Its expiry is a year out rather than
  mirrored: a near-term one would make Claude Code refresh on its own with a
  refresh token that isn't real, logging the session out. Inside the
  container,
  `entrypoint.sh` points `api.anthropic.com` at a loopback TLS terminator
  (`credential-proxy-forwarder.js`) whose certificate is generated at startup
  and trusted only there, and which pipes raw bytes into the proxy's socket.
  The proxy injects the real access token per request and owns OAuth refresh
  - rotated tokens are written back to the real host file atomically, so
  host-side sessions stay logged in. Claude Code itself is configured
  exactly as on the host: no `ANTHROPIC_BASE_URL`, no
  `ANTHROPIC_AUTH_TOKEN`, nothing marking the session as unusual. The proxy
  forwards the client's header block verbatim - same names, casing, order and
  repeats, and no `Accept-Encoding` it didn't send - changing only
  `Authorization`, and `anthropic-beta` if the OAuth value isn't there.
  Neither of those is a name the proxy holds: which header carries the
  credential, what shape it takes, what must not travel beside it and which
  comma-list value has to be present are all arguments, and `bin/dejima`
  supplies the Anthropic ones (#171). The credential kind is an argument too -
  a refreshing OAuth file, or a static key that is read and sent - so a
  backend that cannot be refreshed is not a branch here. Left
  alone, Python's `http.client` would rewrite all of that into its own style
  and move the fingerprint from the client to the wire. It cannot disguise
  that the connection is CPython's `ssl` rather than Node: the TLS handshake
  (JA3/JA4) and the absence of connection reuse still distinguish it.
  What remains is session-scoped: a compromised session can still *use* the
  API as you while it runs, which is inherent to the sandbox working at all,
  but it cannot read a durable credential and exfiltrate it for offline use.
  Caveats:
  `/login` inside the container doesn't work while the proxy is on; the
  refresh flow mirrors a Claude Code internal and may break if upstream
  changes it, in which case the proxy fails loudly (launch abort, 502s on
  API calls) rather than silently; and a 401 that does reach the container
  can make Claude Code clear the fake credential file, showing a logged-out
  session - harmless, since it's a host temp file, and rare, since the proxy
  absorbs 401s with its own refresh-and-retry.
  `[credentials] proxy = off` (in `~/.config/dejima/config`) is the kill
  switch: the credential is then mounted into the container explicitly,
  readable by a compromised session. Setups without a
  `claudeAiOauth` block (API-key
  auth) skip the proxy automatically; there's no stored subscription
  credential to protect.
- **If TLS interception stops working.** The container reaches the API by
  resolving `api.anthropic.com` to the loopback terminator above, whose
  certificate is trusted only inside the container. If Claude Code ever pins
  certificates for that host, the handshake starts failing - typically right
  after an upgrade, as `UNABLE_TO_VERIFY_LEAF_SIGNATURE`,
  `ERR_TLS_CERT_ALTNAME_INVALID`, or a pin-specific error. What
  distinguishes pinning from a merely broken certificate is that
  `curl --cacert /etc/dejima-credential-tls/cert.pem https://api.anthropic.com/v1/messages`
  still succeeds from inside the container while Claude Code does not: the
  certificate is fine, the client is refusing it. **This is not a reason to
  set `[credentials] proxy = off`.** That kill switch mounts the real,
  durable OAuth credential into a container a compromised session can read,
  which is the single thing this whole mechanism exists to prevent.
  Certificate pinning breaks how Claude Code is *addressed*; it has no
  bearing on whether the credential can be kept on the host. Work down this
  ladder instead - the first two rungs keep the credential out of the
  container, and only the "looks like an ordinary session" property degrades.
  First, `[credentials] transport = loopback` (in `~/.config/dejima/config`,
  then relaunch): a plaintext loopback
  forwarder and an explicit `ANTHROPIC_BASE_URL=http://127.0.0.1:18300`, the
  topology this sandbox used before the TLS terminator existed, so pinning
  cannot apply at all. It costs the base-URL fingerprint, two attribution
  fields in the `x-anthropic-billing-header`, and `/remote-control`. Second,
  if even that fails, `ANTHROPIC_UNIX_SOCKET` pointed at the bind-mounted
  socket together with `ANTHROPIC_BASE_URL=http://api.anthropic.com`:
  plaintext HTTP straight over the socket, bypassing TLS entirely while
  keeping the first-party base-URL check truthy. That rung is a direction,
  not a switch: nothing in this repo implements or tests it, both variables
  have to be passed through `docker-compose.yml` by hand, and it depends on
  Claude Code's own support for `ANTHROPIC_UNIX_SOCKET`. It also costs more in
  appearance than rung one: it classifies the session as host-orchestrated
  and emits its own analytics event. Only if both fail, and knowing what it
  gives up, `[credentials] proxy = off` - the one rung that surrenders the
  real credential into the container. Rung one is a supported, tested mode,
  not an improvised workaround; if you reach the third, treat it as a
  temporary state rather than a new baseline.
## What the container sees of Claude Code's `~/.claude`

One harness's inventory, because there is no shared one to give: what a
harness keeps where, and which of it is safe to mount, is the harness's own
answer and each plugin gives it. Cline's is the table in
[configuration.md](configuration.md#what-comes-in-from-your-host); the
reasoning below is what both are built on.

- `~/.claude` is **not** shared with the container as a whole. Its contents
  are enumerated in `docker-compose.yml`, in three classes, and anything not
  listed is container-local: writable during the session and gone with the
  container.
  - **Read-write, because it has to survive the session**: `backups/`,
    `tasks/`, `plans/`, `sessions/`, plus the entries of `projects/` and
    `file-history/` that belong to this workspace. All directories, which is
    what makes them safe (see the detachment note below). The two trees are
    not mounted whole: see
    [One project's session cannot reach another's](#one-projects-session-cannot-reach-anothers).
  - **Read-only**: `plugins/`, `hooks/`, `skills/`, `commands/`, `agents/`,
    `output-styles/`, plus the symlink-target directories `dejima`
    discovers at launch. Those targets are discovered rather than
    configured, so they are checked against the approval store and the
    audit stores and refused if they overlap either - a hook symlinked into
    the approval store would otherwise mount it, read-only and silently, and
    read-only is no protection when the content is every project's
    approvals. The same check covers `[mounts] readonly`. Hooks execute automatically with no separate
    approval step, skills can ship executable scripts, and
    commands/agents/output-styles are prompt text loaded into a later host
    session, so without this a compromised session could plant a backdoored
    hook - including by unlinking one of your own hook symlinks and dropping a
    plain file in its place, since the dynamic per-target mounts only protect
    symlink targets that resolve *outside* `~/.claude`, never this directory
    itself - tamper with plugin code, or drop a malicious
    skill/command/agent/output-style file. Any of those would then run or
    load **unsandboxed on the host** the next time Claude Code starts
    there, turning a single compromised sandbox session into persistent
    host compromise. They may not exist yet on a given host, so `dejima`
    pre-creates them at launch (empty is fine) - Docker can only mount a
    directory that already exists, and without pre-creation a compromised
    session could create and populate one itself.
  - **Copied in, not mounted**: `settings.json`, `CLAUDE.md`, and
    `statusline.sh` are mounted read-only under `/etc/dejima-harness/`,
    at the path they are installed to, and copied into place by
    `entrypoint.sh` as root-owned, unwritable
    files. A session can still unlink and replace them - `~/.claude` belongs
    to it - but only its own copy, which is why they are read-only.

  The reason for the split is that a **single-file bind mount silently
  detaches**. It is pinned to the dentry at its mount point, so when the
  host replaces the underlying file - the ordinary atomic
  write-temp-then-`rename`, performed by Claude Code itself or by any sync
  daemon watching `~/.claude` - that dentry is unlinked and the mount goes
  away with no error anywhere. `docker inspect` still lists it;
  `/proc/self/mountinfo` inside the container no longer does. This was
  found the hard way three times: the generated settings overlay reverting
  mid-session (#47), every other file overlay carrying the same latent bug
  (#48), and the mask over `.credentials.json` detaching on the proxy's own
  first token refresh, exposing the operator's real OAuth access *and*
  refresh tokens to the sandbox (#50). Directory mounts are immune, because
  a rename replaces an entry *within* the mounted directory rather than the
  mount point itself. Enumerating also changes the failure mode: with no
  read-write parent underneath, a mount that somehow did detach falls
  through to an empty container-local path rather than to the host's real
  file. The cost is that anything a future Claude Code version adds under
  `~/.claude` is container-local until it is listed here - it works during
  the session but doesn't persist, which is the safer direction to fail.
- `~/.claude/statusline.sh` (referenced by `settings.json`'s
  `statusLine.command` and executed on the host) is one of the copied-in
  files above, and the case that shows why copying beats mounting. A `:ro`
  mount at its own path protects only the plain-file case - **confirmed
  against a live container**: when `statusline.sh` is a symlink (the
  common case, into a config checkout elsewhere), Docker/runc resolves the
  bind-mount destination through the symlink to its target, so the symlink
  entry itself stays on the writable `~/.claude` mount and remains
  replaceable, with detection the only compensating control. Staging
  turns that same symlink resolution into the fix: it happens on the
  *source* side, so what gets copied in is the real content and the copy
  has no route back to the host (`test/runtime.bats`'s statusline.sh
  tests). `bin/dejima-audit` still hashes `statusline.sh` on the host
  (following a symlink to its target *path string*, so a repointed or
  replaced symlink is caught even though its own inode doesn't change) and
  reports a change as a host-code-execution finding when the session exits.
- `~/.claude.json` mixes that same kind of live state (project registry,
  usage stats, caches) with config (`mcpServers`). Unlike the four above,
  it can't just be layered read-only: Claude Code does an atomic
  write-temp-then-rename against it during normal startup, before login
  even completes, and a read-only file makes that **hang** instead of
  failing cleanly (confirmed against a real read-only copy of this file -
  upstream bug: [anthropics/claude-code#29162](https://github.com/anthropics/claude-code/issues/29162)).
  Instead, `dejima` generates a throwaway copy of the file at
  launch (seeded from the real file, same "generate a sandbox-specific
  file on the host" pattern as the generated settings override layer)
  and mounts *that* read-write in its place; the copy is discarded,
  unmodified in the real file, when the session ends. A compromised
  session can add whatever it wants to `mcpServers` (or anything else in
  the file) - it never reaches the real `~/.claude.json`, so there's
  nothing to persist. This also means multiple concurrent sandbox sessions
  never contend over the same file - each gets its own independent copy.

- DNS resolution itself is allowlisted (see "DNS is allowlisted too" below),
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
  to GitHub by default: port 22 there is blocked unless `--allow-github-push`
  is given, or `[core] forge = github` is selected with a workflow that
  pushes (which opens the same grant), so the forwarded agent otherwise has
  no transport to use for it at all (see "GitHub push: blocked by default,
  optional opt-in" below).
- `[core] ssh_key` (see [Headless git push without agent
  forwarding](configuration.md#headless-git-push-without-agent-forwarding))
  is a second, independent credential-loading path with the same "signs for any
  Gitea repo it has access to" shape as the forwarded agent above - the
  mitigation is that it's meant to be a dedicated deploy key scoped to only
  the repos that actually need push access, not your personal identity.
  That scoping is a convention, not something enforced here: nothing checks
  what `[core] ssh_key` actually points at, so pointing it at your real
  `~/.ssh/id_ed25519`/`id_rsa` instead of a dedicated key would load your
  full personal identity into the container for the whole session (`bin/
  dejima` warns if this looks like it might be happening - see
  below - but doesn't block it). The key source itself is mounted read-only
  at `/root/...`, not under the sandbox user's own home, specifically so
  that user (which the session actually runs as) has no path to read the
  raw key material - only the agent socket it's loaded into.
- The gitconfig copy `dejima` generates (see that mount's
  comment in `docker-compose.yml`) carries over whatever's in your real
  `~/.gitconfig` verbatim. If yours has inline credentials (a
  `[credential]` token, a `url.<token@>.insteadOf` rewrite, a
  `credential.helper store` path), those enter the container along with
  it - an unadvertised secret-carrying path distinct from the
  SSH-agent/token story documented above. Keep credentials out of your
  global gitconfig, or expect them to be reachable from inside the
  sandbox.
- **The egress filter is not in the container the session runs in.** A launch
  starts two: a filter container that owns the network namespace and installs
  the packet filter, and the sandbox, which joins that namespace with
  `network_mode: container:` rather than getting one of its own. Capabilities
  are per process rather than per namespace, so the sandbox cannot alter the
  filter bounding it even at uid 0 - measured, not reasoned: `nft` returns
  `Operation not permitted` to a joiner that lacks `NET_ADMIN`.

  Two things follow. The namespace has its rules before anything is created in
  it, so there is no window in which a session holds an interface and no
  filter; `bin/dejima` waits for the filter container to say it is up and
  refuses the launch otherwise. And killing the filter container leaves the
  sandbox holding loopback alone - no network at all, rather than an unfiltered
  one.

  Nothing a session runs ever executes in the filter container. It holds the
  privilege; the one beside it holds the session. Each launch gets a network of
  its own, so concurrent sessions are separated at the link layer as well.

  A launch removes both on the way out, and reconciles at the start against
  whatever a `SIGKILL` or a restarted host left behind - a filter container
  with no session in its namespace, older than the window in which a pair is
  still being built. What that reclaims is address space rather than safety: a
  leaked filter container filters a namespace nothing is in, and Docker's
  address pool is finite enough that exhausting it fails a later launch with an
  error naming neither cause nor remedy.
- The sandbox's own user (matching your host user; see "Config parity" in
  the README) has no `sudo`/setuid path back to root once the container is up:
  `entrypoint.sh` runs as root, prepares the session's own state, then drops to
  that user before execing the configured command (`[core] command`, or the
  selected harness's own if that is unset). A compromised session can't
  re-run the egress policy with a wider allowlist to open its own
  exfiltration path. The script is in reach - it is the same image, and
  `/usr/local/sbin` is on that user's PATH - and reaching it is not the
  question: it refuses outright as a non-root caller, and the capability it
  would need to change anything belongs to the container beside this one.
  Verified both ways, in `runtime.bats`: the session user cannot run it, and
  root in the session container cannot either.
- **The session's capability bounding set is empty**, not merely its effective
  one. The distinction is the whole of it: an empty effective set is what
  changing uid gives you anyway, while the bounding set is what a process that
  reached uid 0 in that tree would recover its capabilities from. So the two
  claims above - no path back to root, and no capability if there were one -
  hold separately rather than one resting on the other. The drop and the uid
  change happen in one `capsh` process because they have to: the bounding set
  can only be reduced while `CAP_SETPCAP` is still held, and changing uid first
  gives it away. The same applies to `log-shipper.sh`, the one root process
  that outlives the entrypoint.
- A forge credential reaches the container as `-e NAME`, never
  `-e NAME=value`. The value comes from the launcher's own environment, so it
  sits in `/proc/<pid>/environ` (mode 0400, owner only) rather than in
  `/proc/<pid>/cmdline`, which is world-readable and which `ps` prints to
  anyone. `docker inspect` still shows the resolved value to whoever can
  reach the daemon - that is daemon access rather than any process at all,
  and it is not something the launcher can change.
- **Each container runs with `no-new-privileges` and a capability floor of its
  own**, `cap_drop: ALL` plus what that container actually uses. The two lists
  are the arrangement stated as configuration:

  The session container declares **no network capability at all** - not
  `NET_ADMIN`, not `NET_RAW`. It is inside a namespace the filter container
  owns and has already installed the rules in, and capabilities are per
  process, so uid 0 in there is refused by the kernel rather than by policy.
  What it keeps is what its root phase does before the session starts: write
  and chown files, and drop privilege once. `SETPCAP` is there to spend rather
  than to use - it is what lets the entrypoint take the rest of the list away
  again before execing the session, and since Linux 4.3 it grants nothing a
  process does not already hold.

  The filter container holds the network capabilities. The session's list is in
  `docker/docker-compose.yml` and the filter's is in `bin/dejima`, each beside
  the container it describes.

  `KILL` is on both lists, for unrelated reasons, and it is the one worth
  reading twice. The filter container needs it because adding a domain to a
  running session signals dnsmasq, which runs as its own user. The session
  container needs it because `init: true` makes PID 1 an init that forwards
  signals to the session - and the entrypoint changes uid in place before
  exec'ing it, so that is uid 0 signalling a process whose real and saved uids
  are the sandbox user's. Without the capability every forwarded signal is
  `EPERM`, tini treats a failed forward as fatal, and an ordinary terminal
  resize ends the session.

  `no-new-privileges` means a setuid binary or a file capability cannot raise
  privileges on exec, which is the shape any escalation from the session user
  would have to take. The floor means the capabilities nothing uses were never
  in the bounding set to be regained. Both are asserted against running
  containers rather than against the files, and both lists the tests use are
  read out of those files so neither can drift.

  What a floor describes is a container's **root phase**. A launch runs with
  `init: true`, so PID 1 is the init that reaps for the session and it holds
  that container's floor for as long as the container lives; the session is its
  child and holds nothing.
- The approval store (`${DEJIMA_CONFIG_DIR:-$HOME/.config/dejima}`,
  see
  [Global and per-project domains and dependencies](../README.md#global-and-per-project-domains-and-dependencies)
  in the README) lives outside
  this repo, and outside every project mount, by default - unlike a
  project's own `.dejima/` declaration files, it's never
  bind-mounted into the container, so a compromised
  session has no path to write to it at all, let alone plant something for
  the *next* launch to pick up. Its files are read by a small
  line-oriented parser (`approved_entries` in
  `bin/dejima-project-lib.sh`), never sourced or executed, and are
  written only by the CLIs (`dejima-allow`, `dejima-dep`,
  `dejima-project`) a human runs on the host. `dejima`
  warns at launch whenever the resolved store path (default or overridden
  via `DEJIMA_CONFIG_DIR`) lands under the mounted workspace,
  rather than silently trusting it.
- When the mounted workspace *is* this repo itself, `dejima`
  warns at launch that the repo's own trusted computing base - `bin/`,
  `hooks/`, `docker/`, `install.sh` (also `test/`, per the
  exit-time audit's exact TCB path list above) - is writable for the
  session (it's inside the project mount, which has no write protection,
  per above), and that the exit-time audit will report any changes to it.
  That's a warning and a post-hoc report, not a block: a compromised
  session can still edit those files during the run, and whatever it
  changes takes effect the *next* time `dejima` itself runs,
  not the current one.

  The report splits on whether git can see the change. tcb_snapshot only
  populates when the workspace IS dejima's own repo, so an ordinary change
  there is already in the working tree you are about to read in `git status`
  and in the pull request - reporting each one as a CRITICAL to acknowledge
  duplicated a stronger control and made developing dejima itself unusable.
  Those are counted in one INFO line instead.

  A change git *cannot* see stays a CRITICAL finding, because nothing else
  would catch it: a file in `.gitignore` or `.git/info/exclude`, or one
  marked `assume-unchanged` or `skip-worktree`, is live code that runs on the
  next launch and appears nowhere in `git status`.

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

## Declaration files are session-writable

A project's `.dejima/` declaration files sit inside the project mount, which
is bind-mounted read-write. A compromised session can write them, and that is
fine by design: declaring grants nothing, and the approval store the session
cannot reach is what a declaration has to pass through.

What a session *could* try is to make the host-side write land somewhere else.
Plant `.dejima`, or `.dejima/<kind>`, as a symlink pointing at your approval
store or any other file you can write, then get you to run the
`dejima-allow --project` or `dejima-dep add` that appends to it. The append
happens on the host, as you, so it inherits your write access rather than the
container's.

Both writers refuse a symlink at either of those two leaves. The refusal is
the `open` itself and not a check before it: `O_NOFOLLOW` on both, with the
file opened relative to the already-opened directory, so a session still
running while you type the command cannot swap either one out from under the
write. Those two leaves are what a session controls. A symlink further up a
`--project` path you supplied yourself is still resolved through, because
that part of the path is your claim about where the project is, not the
session's.

Expect the session to be live when you run these: the agent briefing tells it
to ask you to run them from a terminal outside the sandbox, which is exactly
the window this closes.

## Network egress firewall

On start, the filter container establishes an allowlist-only egress policy
(`docker/egress-policy`): one `nftables` inet table with a closed default and
everything the session may reach expressed as named sets. Allowed by default:

- DNS resolution via a local proxy (see "DNS is allowlisted too")
- the Docker host itself (not its whole subnet)
- GitHub's published IP ranges, port 443 only (see "GitHub push" below)
- `registry.npmjs.org`, plus whatever the selected harness declares as its own
  (`platform.claude.com` for Claude Code; Cline declares none, so a session
  falling back to Cline's hosted endpoints fails to connect, which is the
  right outcome); `release-assets.githubusercontent.com` (GitHub release
  assets, a separate CDN from github.com's own IPs, and where a good deal of
  tooling fetches its binaries); and the selected backend's API endpoint when
  the credential proxy is off for it

  That is the whole built-in list, and it is meant to stay that way: it covers
  what the sandbox itself cannot run without, not what a project might want.
  Language package hosts are approved rather than assumed: `pypi.org`,
  `proxy.golang.org`, `crates.io` and the rest are one `dejima-allow --global`
  or one reviewed `.dejima/allowed-domains` line away. The reason to keep the
  built-in list short is that everything on it is reachable from every sandbox
  on the host whether or not a project has any use for it, and a name granted
  by being built in is a name nobody ever reviewed
- whatever the selected forge needs reachable (`[forge.gitea] ssh_host`/`api`
  by default): not port-restricted, so git-over-ssh to the forge works
  without a blanket "port 22 to anywhere" rule, and exempted from DNS-rebind
  protection because a self-hosted forge host legitimately resolves to an
  internal address. `[core] forge = github` is deliberately *not* added here:
  its three hostnames are public names already covered by the GitHub entry
  above, so they stay on that entry: 443 by default, plus port 22 when the
  selected workflow pushes, exactly as `--allow-github-push` opens it per
  launch, rather than picking up all-port egress and losing rebind
  protection on the way

Everything else is rejected. Run `dejima-allow --global <domain>`
(or `--project <path>` for one project) to allow more permanently (e.g.
`crates.io` for a Rust project), or `dejima --no-firewall` to disable the
firewall entirely for one launch (debugging only).

Inbound and forwarded traffic default to drop as well, in both families, with
narrow exceptions for loopback, replies to connections the container itself
started, and the container's own host. Nothing in either container is meant to
be reachable from the bridge - the resolver and the credential forwarder both
bind loopback - and a session process that binds every interface is binding one
by accident. A launch puts each pair on a network of its own, so there is
rarely anything else on that bridge to reach it, but that is a property of the
launcher; this is the filter's own answer to the same question. Dropped rather
than refused, which is the opposite of the outbound decision and deliberate: a
refusal is a courtesy to a caller that is supposed to be there.

IPv6 is refused outright. Not filtered alongside IPv4, not allowlisted - a
sandbox has no IPv6 egress at all. An allowlist naming one address family says
nothing about the other, so every restriction above would be worth only as much
as the v6 route to the same host.

It is said twice, pointing the same way. The first rule of the egress chain
refuses the whole family, above even the established and loopback passes, since
a rule below either is one a v6 packet can get past - loopback carries `::1`,
and a flow permitted once stays permitted. And the resolver hands out no AAAA
at all, so a permitted name never produces an address that could become such a
packet. Either alone would hold; both is the posture.

One table is what makes this cheaper to hold than it used to be, rather than a
reason to hold something weaker. The firewall this replaced had to decide
whether the family was even present before it could block it, and the first
version of that read "the tool will not run" as "the family is not there" - so
it ran with IPv6 live and unfiltered, and said nothing. There is nothing left
to infer: the refusal loads in the same transaction as everything else, or none
of it loads. A tool that will not run and a family that is not there are
different conditions, and reporting the second on evidence of the first is how
a boundary comes to be described rather than held.

The startup self-check also resolves every permitted name and reads each answer
back out of the address set its class names, refusing to start if one is
missing. A name that resolves and whose address is not where the ports are
keyed to would be a session that reaches a configured destination only by
accident, or not at all - and the class an entry carries, the resolver line
built from it, and the set the rules use are three separate statements that can
each be right about a different one. A name that returns no address is reported
rather than fatal: that is the world being unavailable, not the policy
disagreeing with itself.

The startup self-check asserts the shape of the ruleset, not a connection that
fails: a v6 connection fails identically on a host with no v6 route, so a probe
alone would pass whether the family is refused or merely absent.

If your Gitea host only resolves via a LAN-local DNS server, make sure the
Docker host itself can resolve it: containers inherit the host's resolver.

### DNS is allowlisted too

Resolution itself is restricted, not just the IP connections made
afterward: the policy runs a local `dnsmasq` with no fallback resolver, and
`/etc/resolv.conf` in both containers is repointed at it. Only permitted names
are forwarded to Docker's real resolver; everything else gets NXDOMAIN.
Without this, a compromised session could exfiltrate data by encoding it into
query names to an attacker-controlled domain, even with no direct connection
ever possible.

Two rules make that hold rather than merely intend it. Reaching a resolver
outside the namespace is restricted by uid: the forwarder, running as an
account the image creates for that and nothing else, and root, because the
container runtime's own embedded resolver forwards onwards from inside this
namespace on some versions and every lookup fails without it. The session user
is neither - uid 1000, no sudo, no setuid binary, no capability to change uid -
so the only resolver it can address is the restricting one, which is what
closes the query-name channel. Root in the session container would be a way
around it; that is the same posture the firewall this replaced had, and
narrowing it further needs a discriminator finer than uid, which the packet
filter cannot express between two containers sharing one namespace. And an answer for
a permitted name that points at a private, loopback or link-local address is
refused, because an answer decides what the allowlist contains and an answer
comes from outside: one influenced reply for a public name would otherwise be
egress to a host on your own network. That refusal is stated twice, once in
the resolver and once independently in the packet filter, so it does not rest
on one component being configured correctly. Destinations you configured
yourself - the forge, Loki, and anything in `[core] internal_domains` - are
exempt, because you chose their addresses and there is nothing for an answer
to decide.

Every lookup is recorded, with its outcome and - for a refusal - its reason.
A refused lookup never becomes a connection, so it would otherwise leave no
trace at all, and it is the query itself that carries data out.

### Adding a domain to a running session

Approved domains only take effect at container start. For a domain a
*running* session needs right now, run from the host (not inside the
sandbox: it has no privilege to do this itself):

```sh
dejima-allow crates.io                    # this running session only
dejima-allow --container <id> crates.io   # a specific session, if more than one is running
```

It runs `egress-policy permit` in the filter container via `docker exec -u
root`, which records the entry, regenerates the resolver's configuration and
restarts it (under a second, losing only its cache), then proves the change:
it resolves the name through the policy's own resolver and confirms the
address reached the set its class uses. If any of that fails it puts the
permitted set back the way it was, so there is no half-added name that
resolves and is then refused. It finishes by checking the domain is actually
reachable from inside the session container and prints a definitive verdict:
exit code 2 if it isn't.

The class comes from the same file the container composes its own lists from,
so a name under a forge suffix is added to the forge class and stays confined
to 443 - adding a domain cannot widen how a destination is reachable, only
whether.

`--global` and `--project` are the opposite of this: they record an approval
for *future* sessions and deliberately do not touch a running container, even
together - see
[Global and per-project domains and dependencies](configuration.md#global-and-per-project-domains-and-dependencies)
in docs/configuration.md, since the domain being approved may legitimately
not answer on 443 (an
internal service, an SSH-only host) and the natural moment to add an approval
is precisely when nothing is running to probe in the first place. Pass
`--container <id>` alongside a scope flag to do both in one call:
`dejima-allow --global --container <id> crates.io` records the approval and
patches that session immediately, in that order, so the approval is never
lost to a live-session failure. If more than one dejima container is
running, the bare form above refuses rather than guessing. On a terminal it
offers the running sessions to pick from, by project; anywhere else - a
script, a pipe, a session asking its operator to run this - it prints the same
rows and stops, because a prompt nobody can answer is worse than a refusal.
Either way the answer is in front of you instead of in a separate `docker ps`.
A session has its own ID regardless: `sandbox-context.sh` hands it to the
agent in its startup context, and `cat /etc/hostname` has it inside the
sandbox, so there is no need for it to guess one and risk "successfully"
updating someone else's session instead.

A domain allowed this way stays allowed for the rest of the session even
if its CDN later rotates edge IPs: the resolver writes every answer it serves
into the address set its entry's class names, not just the one resolved at
allow-time, since only permitted names get an upstream to answer from in the
first place. GitHub's own domains keep their port-443 restriction through it:
what confines them is which class the name is in, and `dejima-allow` reads that
from the same file the container composes its own lists from. The resolver's
longest match decides which set an answer is written into; the ruleset's order
decides which ports that set is reachable on, with the forge class's
permit-and-refuse pair ahead of the open class. Adding a domain can widen what
a session reaches, never how.

An *internal* hostname - one that resolves to an address inside your own
network - is the one case that needs saying twice. The policy refuses such an
answer for a permitted name, because an answer decides what the allowlist
contains and comes from outside, so one influenced reply for a public name
would be egress to a host on your network. Destinations dejima resolves itself
(`[forge.gitea] ssh_host`, `api`, `[logging] loki_url`) are exempt, because you
configured their addresses and there is nothing for an answer to decide. An
approved domain is not: `.dejima/allowed-domains` is reviewed with the project
and expected to carry public names.

So an internal host you approve also goes in `[core] internal_domains`. Both
halves read that one key: a launch exempts those entries and nothing else, and
`dejima-allow` passes the same exemption only for a name that is in it. Adding
such a name to a running session works when it is listed and is refused when it
is not, with the refusal naming the key - rather than the two commands having
different ideas and the disagreement surfacing as a failed launch later.

The session briefing tells the agent to ask for this by name when a task is
blocked on a single missing domain, rather than stopping the whole session
over it.

### The firewall bounds the container, not the harness

Everything above is about what the *container* can connect to. A harness may
also offer the session a tool whose network request does not come from the
container at all, and the allowlist has no view of those.

Claude Code's `WebSearch` is the instance to reason from. Observed in one
session, in this container:

```
$ curl https://aider.chat/docs/config/options.html
curl: (6) Could not resolve host: aider.chat
```

and in the same session, `WebSearch` returned that page's content. The
retrieval did not use the container's network, because the container has no
route to that host. The only channel into a session that is not the
container's own network is the model API connection - which dejima already
routes through the host-side credential proxy - so the search ran on the API
side and its result arrived in the model's response.

That cuts both ways, and neither is closed here:

- **Inward.** Text from any site on the internet can enter the session without
  the DNS allowlist seeing the name. The allowlist is described elsewhere in
  this document as bounding where a prompt injection could fetch its next
  instruction from; that is true of anything the container fetches, and not
  true of this.
- **Outward.** A search query is session-controlled text sent to a third
  party. It is low bandwidth next to an HTTP body, but it is a channel out
  that no `.dejima/allowed-domains` line was ever reviewed for.

What this is not is unmonitored. The traffic rides the model API connection,
which in the default configuration is exactly the connection dejima terminates
in-container and forwards through its own host-side proxy - so it crosses a
process the operator runs. dejima does not inspect what crosses it, and this
document does not claim it does.

The lever an operator has is the harness's own, not dejima's: Claude Code
takes a `permissions.deny` entry for a tool name, and dejima already writes a
settings overlay it could go in. It is not written there by default, because
the tool is useful and the exposure is a search query rather than a file.

**This is not a Claude Code quirk, it is a harness question**, and the second
harness answers it the other way. Cline ships a web-fetch tool too, and it was
put to the same test in the same container: asked to fetch that same
`aider.chat` page, the tool ran and came back "Unable to connect", exactly as
`curl` does. The fetch happens in the container, so the allowlist bounds it,
and for Cline the paragraphs above simply do not apply.

So which side a harness's network tools run on is a per-harness fact that has
to be established by running them, not inferred from the tool having a similar
name. It belongs in that harness's worked example in
[development.md](development.md#adding-a-new-harness) alongside the rest of
what it can and cannot do.

## The one request dejima itself makes

Everything above bounds what a *session* reaches. dejima's own host side
reaches one place, once an hour at most: `bin/dejima-update-check` asks the
remote your checkout already tracks for the tip of the branch it already
follows, so that a launch can say when the checkout is behind. It is
`ls-remote`, so no objects are downloaded, and `[core] update_check = off`
stops it entirely. There is no other endpoint and no telemetry - a domain
you have not already configured dejima to push to is never contacted.

It reaches that remote by URL, from outside the repository, and never by
remote name. `git ls-remote origin` reads the checkout's own config for how
to get there, and `core.sshCommand`, `credential.helper` and
`url.<base>.insteadOf` each name a command git then runs on the host. dejima
mounts its own checkout writable when that checkout is the workspace, so a
session that wrote `.git/config` there would otherwise get host execution out
of the next launch. That is the same class as the `core.hooksPath` route
above, with one difference worth stating: `hooksPath` waits for the operator
to run a git command, and a check that runs at every startup does not wait
for anything. Handing the URL to a git started outside the repository leaves
none of that config in the path, and `protocol.allow` holds the transports to
ones that cannot name a command.

What still crosses is the URL itself, which a session with that same write can
point at a host of its choosing. That costs one outbound request and no
execution, and the audit reports the config change it took.

## Network request logging

If `[logging] loki_url` is set (see Prerequisites in the README), every DNS query and every new
outbound connection attempt - allowed or rejected - is shipped to that Loki
endpoint. Two sources, both tailed and pushed by `log-shipper.sh`:

- every name lookup is recorded as one JSON object, with its outcome and, for
  a refusal, its reason: not permitted at all, permitted but answered with an
  address inside a private network, or permitted and no such name. The second
  carries a severity, because it is someone trying to steer the policy rather
  than a name nobody was allowed to ask for. Labeled `job=dejima-dns`. A
  refused lookup never becomes a connection, so this is the only record it
  leaves - and it is the query itself that carries data out.
- the policy tags its terminal permit/refuse rules with `NFLOG`, on two groups
  rather than one prefix to parse, which `ulogd2` turns into JSON lines with
  source/dest IP, port, and an `action` field - labeled `job=dejima-net`. Its
  configuration is generated per launch alongside the ruleset, so the group
  numbers cannot drift from the rules that write to them. Only new connection
  attempts are logged, not every packet: the chain's ESTABLISHED,RELATED rule
  short-circuits the rest of a connection before it ever reaches the tagged
  rules.

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
than DNS names and firewall verdicts, so nothing is shipped unless you
opt in. Transcripts of every session under the mounted workspace
(including worktrees and subagent sessions) are shipped while the sandbox
runs.

**It ships from the host, not from inside the session.** The transcripts
are bind-mounted from the host rather than produced in the container, so
`bin/dejima-conversation-ship` reads them where they already are. That
matters because this is an oversight log of the session it is watching:
run inside, it was a process the session shared a filesystem and a signal
namespace with, and a session that killed it ended its own logging with
nothing on the host noticing. DNS and firewall logs still ship from
inside, because those files only exist in the container.

What that does **not** change is that the transcript is session-writable.
This ships what was recorded; it does not attest to it - the same caveat
[epitaph](configuration.md#reading-what-a-session-left-behind) carries.

**And it moves a parser across the boundary.** The transform is `jq`, and it
reads session-controlled bytes on the host as your user rather than in the
container as root. That is the trade, not a free win: what
is gained is that a session can no longer silence or edit its own oversight
log, and what is accepted is that `jq` is load-bearing against hostile input
outside the container. It is the same bet epitaph already makes with
`python3`, and the reason the parser is a plugin's rather than something a
manifest could supply.

### Viewing logs in Grafana

Nothing sandbox-specific needed on the Grafana side beyond a Loki data
source pointed at wherever `[logging] loki_url` resolves to (Connections → Data
sources → Loki, if one isn't already configured against that instance) -
`log-shipper.sh` pushes directly to Loki's HTTP API, there's no Prometheus
scrape target or exporter involved.

In Grafana's Explore view (or a dashboard panel with a Loki query), each
stream is selectable by its `job` label:

```logql
{job="dejima-dns"}                          # every DNS query + verdict
{job="dejima-net"}                          # every connection attempt, as JSON
{job="dejima-conversation"}                 # the session itself, if opted in
```

Useful filters on top of those:

```logql
# DNS lookups that got refused (not on the allowlist)
{job="dejima-dns"} | json | outcome="refused"

# Rejected connections only (parses ulogd2's JSON, filters on its action field)
{job="dejima-net"} | json | action="blocked"

# All three together, e.g. to watch a live session across sources
{source="dejima"}
```

The conversation stream, when `[logging] conversation` is on, is one JSON
object per line carrying `session`, `role`, and either `text` or a `tool` name
with its `input`:

```logql
# Just what you asked for, without the replies
{job="dejima-conversation"} | json | role="user"

# Every shell command a session ran, and with what arguments
{job="dejima-conversation"} | json | tool="Bash"

# One session end to end, id taken from a line you already found
{job="dejima-conversation"} | json | session="0198e2c1-..."

# Anything a session said about a subject, across every session
{job="dejima-conversation"} |= "allowed-domains"
```

`session` is deliberately a field inside the line rather than a Loki label:
one label per session would multiply the stream cardinality by the number of
sessions you have ever run, which is how a Loki instance stops being usable.
Filter on it with `| json | session=` as above rather than expecting a
selector.

Two things are absent by design. **Tool results are never shipped**, only
invocations, so a query will show you that a session ran `Bash` with certain
arguments and never what came back. **Thinking blocks are never shipped either.** Both dominate the volume
and neither was what opting in asked for. Long values are clipped, so a very
large prompt or tool input ends in `...[truncated]` rather than being dropped.

`{job="dejima-net"}` lines are one full ulogd2 JSON object per
connection attempt (`| json` in a query unpacks fields like `dest_ip`,
`dest_port`, `action`) - Loki's Explore view shows these expandable/
pretty-printed by default, no extra parsing setup needed.


## GitHub push: blocked by default, optional opt-in

`dejima --allow-github-push` is a per-launch *addition* to whichever forge is
selected, not a substitute for selecting one. A pushing workflow is still
refused at launch unless its forge resolves to a host with its required keys
filled in, so the flag alone will not get an unconfigured `[forge.gitea]` past
validation.

This section is about `--allow-github-push`, a per-launch flag that adds
GitHub as a push destination on top of whichever forge is selected, without
changing that selection. It adds a destination; it does not stand in for a
forge, so the launch-time rules for the selected forge/workflow pair still
apply exactly as they would without it. If you
want GitHub push and PRs as a standing choice instead, set
`[core] forge = github` (see
[Shipped providers](providers.md#shipped-providers)): it also opens
`ssh.github.com:22`, but persistently rather than per launch, and uses its
own `[forge.github] push_token_file` rather than a loaded SSH key.

**Why the default is off.** The principle is narrower than CI and holds
whether or not CI exists anywhere: *a session that is not being used to push
to a forge should not be able to push to it.* Your configured forge is the
one you chose to push to. GitHub is where everything else lives - every
dependency a session reads, every repository it clones to understand an
error - so that is where the rule bites by default.

The case is an eager agent, not a compromised one: it finds a real bug in an
unrelated open-source project and pushes a fix branch to somebody else's
repository. That this is not an attack does not make it harmless. Maintainers
are already triaging a flood of unsolicited AI-generated pull requests, and
one more arriving in your name, unreviewed, is a cost imposed on someone who
did not ask for it. The block exists so that it cannot happen, not so that
you get to approve it first.

[Don't point it at repositories you don't own](responsible-use.md#dont-point-it-at-repositories-you-dont-own)
is the rule this enforces, and gives the fork-and-review workflow to use
instead: work against your own fork, review the result, and open the upstream
pull request by hand if you still want to.

Closing the CI chain follows from this - a push is code execution on whatever
runners that repository can reach, per the section above - but it is not the
reason for it. Reading it the other way round gets the order backwards, and
makes the default look like a CI workaround to be turned off once CI is
handled.

The sandbox can always read from GitHub (clone, fetch, `gh` API calls). By
**default** it can never push there: enforced at the network layer, not
just by `git-push-guard.sh`. GitHub's IP ranges are only allowlisted on port
443. Port 22 is unreachable, so SSH-based push has no transport at all,
regardless of what any hook does or doesn't catch.

**Opt-in, not hardcoded**: pass `--allow-github-push` to open port 22 to
GitHub and let `git-push-guard.sh` accept `github.com`/`ssh.github.com` as a
push destination (the no-direct-to-main rule still applies):

```sh
dejima --allow-github-push ~/repos/some-project
```

**Read this before turning it on.** Whether a push actually succeeds depends
entirely on what SSH key is loaded into the agent. A forwarded personal
agent with your normal GitHub key would let a compromised session push to
**any** repo that key can write to, not just the one you intended: agent
forwarding doesn't distinguish push from pull. Use a dedicated,
**repo-scoped GitHub deploy key** via `[core] ssh_key` instead whenever
`--allow-github-push` is set: that's what actually limits the blast radius.
`--allow-github-push` only changes the firewall/hook's *host* check; it adds
no credential-loading path of its own. The flag itself has no config-file
equivalent: an exported or saved value must not silently grant a push path,
so *this* opt-in stays a per-launch decision only. Selecting `[core] forge =
github` (see [Shipped providers](providers.md#shipped-providers)) is a
config-file path that opens the same port, but not
silently: `hosts_allowlisted_by_core` is what asks for it, explicitly, in a
manifest, and only when the selected workflow actually pushes. What it opens
is the same GitHub ranges the read-only path already allows on port 443, now
also on port 22, logged like every other allowed connection.

The startup self-check covers the default. With the opt-in off it asserts port
22 is refused and stops the container if it is not; with the opt-in on it skips
that one check, and says so in the log. Everything else it asserts still
runs. So a break in the opt-in plumbing
surfaces as a failed `git push` rather than as a container that refuses to
start. `test/runtime.bats` asserts the open direction against a real container
pair, which is where that property is covered.

`[github] token_file` must point at a **read-only** fine-grained PAT
regardless of this setting. `gh auth setup-git` (run at container start if
that file exists) points git's github.com HTTPS credential helper at `gh`,
which only ever holds whatever token that file provides: a write-scoped
token there would make HTTPS push possible independent of
`--allow-github-push`, so don't use one.


## What none of this closes

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
  would defeat every other control described here at once. What such an
  escape then reaches is a layer dejima cannot bound, because dejima runs
  inside it:
  [dejima-devbox-hardener](https://gitbox.branderson.io/dejima/dejima-devbox-hardener)
  is the project for that, and [threat-model.md](threat-model.md) has the
  row-by-row account of where each layer's compromise stops.
- Most of what this document asserts is re-checked by the `test/` suite on
  every change, and `runtime.bats` asserts against a real running container
  rather than a mock: IPv6 blocked, a non-allowlisted domain refused and a
  non-allowlisted destination unreachable, `node` unable to re-run
  the egress policy, no working `sudo`. Coverage is not completeness: the
  reasoning here is judgement, nothing tests it, and a property nobody wrote
  a test for can regress quietly. A missing address-set dedup flag broke firewall
  startup twice before anyone caught it; there is a test for that now, which
  is the pattern to expect - each of these exists because something was got
  wrong first.
