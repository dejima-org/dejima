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

The provider directories are in the exit-time audit's TCB list for that
reason, alongside `bin/`, `hooks/`, `docker/` and `test/`. They hold no code
and nothing executes them, but what they hold decides what the next launch
permits: a forge's `fixed_hosts` reaches `DEJIMA_FORGE_HOSTS`, which
`entrypoint.sh` joins into the domains `init-firewall.sh` allowlists, so a
line added to a manifest widens the egress boundary on the next run. An
ordinary edit is a diff you are about to read and is not reported; one git
cannot see - hidden by `.gitignore`, `.git/info/exclude`, `assume-unchanged`
or `skip-worktree` - is a CRITICAL finding. It is still a change a session
can make; it is one the audit reports. See
[docs/providers.md](providers.md) for the full manifest contract.

## The mounted project is fully writable

- Running the harness with its permission prompts off removes your chance to
  review tool calls before they run. Only point this at trusted repositories.
- The mounted project itself has **no write protection**. `deny-dangerous-
  bash.sh`, `git-push-guard.sh` and `merge-guard.sh` are regex
  pattern-matching on the literal Bash command string - a fast-fail guard
  against an overeager agent doing something obviously destructive, not a
  boundary against one that's actively trying to get around them (a
  different scripting language, an encoded command, editing `.git/config`
  directly all sail right through).
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
  The workspace's own `.git/hooks` directory is mounted read-only
  (same pattern as the `~/.claude` code directories below), so planting a hook
  file directly is closed - accepted breakage: installing hooks
  *in-session* (`husky`, `pre-commit install`) fails, which is the
  point. `core.hooksPath` and `.claude/settings.local.json` aren't
  overlaid (they're config, not fixed paths a static mount can cover) and
  remain fully writable; the exit-time audit below reports changes to
  either, but only after the session ends - it doesn't stop them.
## The exit-time audit

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
  hashed by its target, not just its content). When the mounted workspace is
  this repo itself, it also hashes the sandbox's own trusted computing base -
  `bin/`, `hooks/`, `docker/`, `install.sh`, `test/`.

  Worth knowing about that first surface, because the sandbox's own workflow
  makes it easy to get wrong: **a git worktree isolates the working tree, not
  `.git/config`.** Config is shared with the parent checkout, so a bare
  `git config <key> <value>` inside a worktree writes the real repository's
  config, including any exec key above. The briefing now says so, and gives
  `git -C <path> config`. A guard against an unaware agent, not a boundary:
  `.git/config` is in the read-write project mount and cannot be read-only
  without breaking `git push -u`, which writes `branch.<name>.merge` on every
  push. Detection covers the rest, and did - this was found by the audit
  reporting a `.git/config` change.

  **Advisory only.** It fires after the session ended, so a planted
  `core.hooksPath` is something to clean up before the next `git` or
  `claude` in that repo, not something that was blocked. Silent when nothing
  changed, and never affects the session's exit code. It does not cover
  `[core] share_dir` (see
  [Shared scratch space](configuration.md#shared-scratch-space)), and its
  coverage is a fixed list rather than a general integrity check, so a config
  surface it has not been taught about goes unreported.

  **Its diff is time-windowed, not session-attributed:** a finding means a
  path changed while the session ran, not that the session changed it. A
  concurrent session, another host process, or your own editing all land in
  the same diff, reported identically.
- **Approving and ignoring are different decisions, and the difference is
  what you are promising about next time.** Approving records the exact
  content: `safe <id> <sha>`, so this file with these bytes is fine and any
  other content re-fires. Ignoring records the surface: `spam <id>`, so this
  path or key is fine whatever it later contains. Approve a hook you have
  read; ignore a key some tool rewrites on every run and which you have
  decided you will never care about. The review offers both, and says which
  is which rather than leaving you to infer it:

  ```
  [a] approve this exact content  [i] ignore this key from now on  [s] skip (ask again next time)  [q] quit
  ```

  A finding whose file has since been deleted is **cleared** rather than
  approved: there is no content left to pin an approval to, and a surface
  that does not exist does not run. Nothing is recorded, so if it comes back
  it comes back as a new finding. Refusing would leave the report
  unresolvable: `ack` opens CRITICAL reports first, so every other report
  would hide behind one no decision could clear.

  Skipping asks again next session, the right default when you are unsure.
  It matters for keys some tools rewrite on every run: with no decision
  recorded, one re-fires every session and pushes real findings out of the
  capped list.

  Severity is not negotiable by either verb. An exec-capable key or shell
  alias is CRITICAL whatever the baseline says, and an `ignore` entry is
  refused against a CRITICAL surface when the baseline is read, not only when
  written - so neither decision can quietly downgrade something that matters.

- `dejima-audit ack` shows what it is asking you to approve. For a surface
  that changed during the session it prints a unified diff of the
  pre-session content against the current content; for one created during
  the session it prints the whole current content. To make that possible,
  `snapshot` stages a copy of each monitored surface's bytes for the
  duration of the session, and `compare` turns those into **bounded
  diffs** stored in a `<report>.d/` directory beside the report. What
  persists after the session is only the diff of a *modified* surface -
  never a whole file. A created surface stores a marker (its content is
  live on disk); a removed one stores nothing at all, because a deletion
  diff *is* the whole former file.

  What it prints is chosen by what changed, which is not always what you
  need in order to judge it - three changed lines in a hook script are only
  judgeable by reading the script. `[o]` at the prompt opens the file in
  `$VISUAL`/`$EDITOR`, read-only where the editor understands how, and
  returns to the same decision. It opens the file **as it is now**, not the
  text the report captured, for the same reason an approval pins the content
  that is on disk at the moment it is recorded: approving something nobody
  read would be the one outcome worse than not asking.

  Staging and retained diffs live under `$AUDIT_DIR`
  (`~/.local/share/dejima/audit`), never `/tmp`. That is the boundary the
  scheme rests on: nothing in `docker-compose.yml` covers it, so the
  container cannot read earlier runs' retained content, and `static.bats`
  pins that. A store configured *inside* the workspace is readable and
  deletable from the sandbox, so nothing is retained in that case - only a
  note saying why.

  A `SIGKILL`ed session runs no EXIT trap and leaves its staging directory;
  the next run against that workspace reaps it, identifying dead owners by
  pid and process start time from an `.owner` file so a concurrent session is
  never mistaken for dead. A missing or unreadable owner record falls back to
  a 24-hour age check rather than guessing.

  Content is withheld from the store in several further cases, and in
  every one `ack` prints the reason in place of the diff - so an absent
  diff is never mistaken for an absent change - and still shows the live
  current content on your terminal, because withholding is about the
  persistent store, not about what you are shown while deciding. Surfaces
  that hold credentials by convention are never staged in the first
  place, so their bytes are never even copied transiently: `.envrc`,
  `.mcp.json` and `.claude/settings.local.json` by exact path, and
  `.env`/`.env.*` by *basename*, at any depth - so a nested `.claude/.env`
  is caught too, not just one at the workspace root. A surface that
  existed before the session but was too large to have been staged (over
  1 MiB) withholds with "no pre-session copy", not a false claim that it
  is new. The *current* side is bounded by that same 1 MiB cap, and - like
  the staged side - checked *before* any copy is taken: a file the session
  grew past it withholds with "change too large to retain" rather than
  being copied through `$TMPDIR` first. The ordering is the point, not the
  cap. `compare` runs from the exit trap on every exit and the size is the
  session's own choice, so copying first would turn "I filled my own
  workspace" into that many bytes written to `$TMPDIR` - often a tmpfs, so
  host RAM - and into a whole copy left there if the exit was a `SIGKILL`.
  A generated diff is withheld if it is binary, over 200 lines
  or 64 KiB (and is bounded to that as it is generated, for the same
  reason), or matches a best-effort credential screen - vendor prefixes
  including `sk-ant-`, `sk-proj-`, `ghp_`, `gho_`, `github_pat_`,
  `glpat-`, Slack's `xox[baprs]-`, `AIza`, `AKIA`, `_authToken`,
  `Authorization: Bearer`, and PEM private-key headers, matched
  case-insensitively, since `.claude/settings.json`'s `env` block - the one
  high-value surface this is the only net for - conventionally holds its keys
  upper-case. The screen is best-effort with real false negatives: the
  denylist above is the reliable half.

  A git config key with more than one value on either side is not compared.
  Git resolves such a key to its last value in FILE order; the audit parses
  and sorts, so lexicographically-last is not what git runs, and the
  pre-session side is every value the key had. Comparing anyway produced a
  diff over values git does not use - two pre-session values read as a
  deletion that never happened, while the appended value git now executes
  appeared nowhere. It withholds instead, and must be compared by hand.
  `include.path` is legitimately multi-valued, so this is an ordinary shape.

  A diff can also come out empty when the config file's TEXT changed but the
  parsed value did not, e.g. a re-quoted value. That withholds too, saying so
  rather than showing nothing - an empty diff for a reported change reads as
  a bug.

  A per-report **retention budget** (`RETAIN_BUDGET`, 1 MiB) bounds the total
  diff bytes one report keeps. Once spent, the rest withhold and both the
  report and the stderr summary add an alarm line: that many changed
  host-persistence surfaces in one session is a signal in itself, not a limit
  worth raising. `diffs = off` in `[audit]` disables retention and staging.

  Two residual limits on top of the screen's false negatives. The prompt
  truncates at 40 lines, naming the file so you can read the rest - a large
  planted change is cut exactly where you would want it whole. And the
  `SIGKILL` case is an exposure window, not just a cleanup mechanic: until
  the next run reaps it, the staging directory holds whole pre-session file
  copies of every monitored surface, for as long as the workspace goes
  unused.
- Findings name a path or config key the session may have chosen, so they
  reach your terminal as untrusted text. One containing an ASCII or C1
  control or a Unicode bidi override - which can scroll, blank or reorder
  what you read, and split a name across the audit's own records - is written
  hex-encoded behind a `{hex}` marker and decodes with
  `printf '%b' "$(sed 's/../\\x&/g' <<< HEX)"`. Ordinary names print as-is,
  so the marker appearing is itself worth a look. The encoded form is what
  `ack` records, so what you acknowledge is the file on disk rather than a
  readable approximation of its name.
## One project's session cannot reach another's

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
- Epitaphs - the summary a session leaves when its context is compacted away -
  are kept host-side in `[epitaph] dir`, and that directory is never mounted. A session can neither read what earlier
  sessions concluded nor edit what this one is about to record, which is the
  same arrangement as the audit store and for the same reason. The transcript
  they are extracted from *is* session-writable, so a summary records what was
  there rather than vouching for it - and nothing loads one back into a later
  session, deliberately: that would be the channel #104 closed, rebuilt.
## The model API credential never enters the container

**This assumes the host has one.** dejima authenticates nothing: the proxy
holds a credential the harness wrote on the host, so a machine where the
harness has never signed in has nothing for it to hold. The proxy then does
not start, no credential is mounted, and the session comes up unable to
reach the model - which reads as a dejima fault rather than a missing
prerequisite. Sign in on the host first; see the README's
[Sign in on the host first](../README.md#sign-in-on-the-host-first).
Refreshing an expired credential is the same: on the host, not from inside a
session, where the credential deliberately never goes.

- The Anthropic OAuth credential (`~/.claude/.credentials.json`) never
  enters the container. It isn't mounted: `~/.claude` is not shared as a
  whole (see the mount inventory below), so there is no path from
  inside the container to that file. `dejima` starts a host-side proxy
  (`bin/dejima-anthropic-proxy`) on a per-session unix socket and mounts a
  fake credential in place of the real one - the secrets are placeholders,
  while `scopes`/`subscriptionType`/`rateLimitTier`/`clientId` are copied so
  the session's UI stays accurate. Its expiry is a year out rather than
  mirrored: a near-term one would make Claude Code refresh on its own with a
  refresh token that isn't real, logging the session out. Inside the
  container,
  `entrypoint.sh` points `api.anthropic.com` at a loopback TLS terminator
  (`anthropic-proxy-forwarder.js`) whose certificate is generated at startup
  and trusted only there, and which pipes raw bytes into the proxy's socket.
  The proxy injects the real access token per request and owns OAuth refresh
  - rotated tokens are written back to the real host file atomically, so
  host-side sessions stay logged in. Claude Code itself is configured
  exactly as on the host: no `ANTHROPIC_BASE_URL`, no
  `ANTHROPIC_AUTH_TOKEN`, nothing marking the session as unusual. The proxy
  forwards the client's header block verbatim - same names, casing, order and
  repeats, and no `Accept-Encoding` it didn't send - changing only
  `Authorization`, and `anthropic-beta` if the OAuth value isn't there. Left
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
  `curl --cacert /etc/dejima-anthropic-tls/cert.pem https://api.anthropic.com/v1/messages`
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
## What the container sees of `~/.claude`

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
    hook - including by unlinking one of `install.sh`'s hook symlinks and
    dropping a plain file in its place, since the dynamic per-target mounts
    only protect symlink targets that resolve *outside* `~/.claude`, never
    this directory itself - tamper with plugin code, or drop a malicious
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
- The sandbox's own user (matching your host user; see "Config parity" in
  the README) has no `sudo`/setuid path back to root once the container is up:
  `entrypoint.sh` runs as root, sets up the firewall directly, then drops to
  that user via `gosu` before execing the configured command (`[core] command`,
  or the selected harness's own if that is unset). A compromised session can't
  re-run `init-firewall.sh` with a wider allowlist to open its own
  exfiltration path. Verified: capabilities (`NET_ADMIN`/`NET_RAW`) are
  cleared from the effective/permitted sets on the `gosu` drop, and that
  user gets a permission error running `iptables` directly.
- A forge credential reaches the container as `-e NAME`, never
  `-e NAME=value`. The value comes from the launcher's own environment, so it
  sits in `/proc/<pid>/environ` (mode 0400, owner only) rather than in
  `/proc/<pid>/cmdline`, which is world-readable and which `ps` prints to
  anyone. `docker inspect` still shows the resolved value to whoever can
  reach the daemon - that is daemon access rather than any process at all,
  and it is not something the launcher can change.
- The container runs with `no-new-privileges` and an explicit capability
  floor - `cap_drop: ALL` plus the ones it actually uses: what the
  entrypoint's root phase needs, and `KILL`. `KILL` is there for
  `dejima-allow --container`, not for the entrypoint - adding a domain to a
  running session signals dnsmasq, and dnsmasq runs as its own user. The list
  itself is in `docker/docker-compose.yml`, which is where it stays correct. The first means a setuid binary or a file capability cannot raise
  privileges on exec, which is the shape any escalation from the session user
  would have to take; the second means the capabilities nothing here uses were
  never in the bounding set to be regained. Both are asserted against a running
  container rather than against the compose file, and the capability list the
  test uses is read out of that file so the two cannot drift.
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

IPv6 is blocked outright (`ip6tables` DROP on INPUT/OUTPUT/FORWARD, `dnsmasq`
strips AAAA answers): there's no IPv6 equivalent of the allowlist above, so
leaving it open would bypass the whole firewall on any host with IPv6
egress.

Where `ip6tables` cannot be used at all, the firewall does not conclude that
IPv6 is therefore absent - it asks the kernel, and treats an address on any
interface other than loopback as the family being live. It then turns IPv6
off in the container's own network namespace, and **refuses to start** if it
cannot. A tool that will not run and a family that is not there are different
conditions, and reporting the second on evidence of the first is how a
boundary comes to be described rather than held.

If your Gitea host only resolves via a LAN-local DNS server, make sure the
Docker host itself can resolve it: containers inherit the host's resolver.

### DNS is allowlisted too

Resolution itself is restricted, not just the IP connections made
afterward: `dns-proxy.sh` runs a local `dnsmasq` with no fallback resolver,
and `/etc/resolv.conf` is repointed at it. Only names on the same allowlist
above (plus `github.com`/`githubusercontent.com`/`githubassets.com`, needed
since GitHub itself is allowlisted by IP range; see `fixed-domains.sh`) get
forwarded to Docker's real resolver; anything else gets no upstream
configured at all and is refused outright. Without this, a compromised
session could exfiltrate data by encoding it into query names to an
attacker-controlled domain, even with no direct connection ever possible.

### Adding a domain to a running session

Approved domains only take effect at container start. For a domain a
*running* session needs right now, run from the host (not inside the
sandbox: it has no privilege to do this itself):

```sh
dejima-allow crates.io                    # this running session only
dejima-allow --container <id> crates.io   # a specific session, if more than one is running
```

It first adds the domain to the running dnsmasq's allowlist (appends a
`server=` line to its servers-file and sends `SIGHUP` to reload just that
file - no restart), then resolves it through the now-unblocked container
resolver and adds the IP(s) to the running firewall's `ipset`, all via
`docker exec -u root`. It finishes by checking the domain is actually
reachable from inside that same container and prints a definitive verdict:
exit code 2 if it isn't.

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
if its CDN later rotates edge IPs: `dns-proxy.sh` tops up the firewall's
`ipset` from every DNS answer it serves, not just the one resolved at
allow-time, since only allowlisted names get an upstream to answer from in
the first place. GitHub's own domains sit outside this - their existing
port-443-only `ipset` entries still win by dnsmasq's longest-match rule -
so that restriction is unaffected.

One gap remains: allowing an *internal* hostname (one that resolves to an
RFC1918 address) mid-session doesn't work. dnsmasq's `stop-dns-rebind`
rejects private answers for any domain not exempted at startup, and that
exemption list can only be extended by restarting dnsmasq. `dejima-allow`
re-asks the container's upstream resolver when a name fails to resolve, so it
names this case and the relaunch that fixes it rather than reporting the host
as unresolvable and sending you to look at a DNS server that is working.
Internal hosts named before the container starts (`[forge.gitea] ssh_host`,
`api`, `[logging] loki_url`, and any globally or per-project approved domain)
are already exempted and unaffected by this.

The sandbox-context.sh `SessionStart` hook tells the agent to ask for this
by name when a task is blocked on a single missing domain, rather than
stopping the whole session over it.

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
{job="dejima-dns"} |= "REFUSED"

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
also on port 22, logged like every other allowed connection and verified by
the firewall's own startup self-check.

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
  `init-firewall.sh`, no working `sudo`. Coverage is not completeness: the
  reasoning here is judgement, nothing tests it, and a property nobody wrote
  a test for can regress quietly. A missing `ipset` dedup flag broke firewall
  startup twice before anyone caught it; there is a test for that now, which
  is the pattern to expect - each of these exists because something was got
  wrong first.
