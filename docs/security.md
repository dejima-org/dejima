# Security notes

[← dejima README](../README.md)

**Threat model, honestly stated:** this reduces the blast radius of a
misbehaving or prompt-injected coding agent - it does not make it safe to
point at arbitrary untrusted or adversarial input, and it does not turn
`--dangerously-skip-permissions` into something without real risk. Point it
at repositories you already trust. Everything below is about how bad a
compromised session *inside* that trust boundary can get, not a claim that
one can't happen.

## CI: push access is code execution elsewhere

The controls in this document bound what a session can reach *directly*. They
do not bound what it can arrange to have run somewhere else, and if the
project has CI, **granting a session push access grants it code execution on
whatever host that CI runs on.** No operator action is needed anywhere in the
chain: the push guard permits a feature branch, the briefing tells the agent
to open a pull request without asking, `on: pull_request` fires, and the
runner checks out that commit and executes it. The you-merge-not-the-agent
gate sits strictly downstream — by the time anyone reads the diff, it has
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
— changing the trigger, dispatching by hand, leaving the runner stopped, the
forge's own fork-PR approvals, filtering egress from inside the workflow — is
reachable from the branch, covered by a credential the session already holds,
or not a gate at all. The mitigations are environmental instead: a runner host
you are willing to lose, job containers with no Docker socket, deny-by-default
egress whose allowlist is read from `main` rather than from the branch, and no
secret a run does not need. And where none of that is available, declining the
push grant declines the code execution with it — `[core] forge = none` with
`[core] workflow = local-only`.

This applies to any project developed in a dejima sandbox, not only to this
repository. **→ [docs/ci.md](ci.md)** for the reasoning and the setup.

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
hands to whichever session starts against it. See
[docs/providers.md](providers.md) for the full manifest contract.

- `--dangerously-skip-permissions` removes your chance to review tool calls
  before they run. Only point this at trusted repositories.
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
  The workspace's own `.git/hooks` directory is now mounted read-only
  (same pattern as the `~/.claude` code directories below), so planting a hook
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
  complete. It doesn't cover `[core] share_dir` (see "Shared scratch
  space") - that hand-off path stays unaudited - and its coverage is a
  fixed list of known Claude Code config surfaces, not a general integrity
  check, so a future config surface this list hasn't been taught about yet
  would go unreported. **Its diff is time-windowed, not session-attributed:**
  a finding means one of these paths changed while the session was running,
  not that the session made the change. A concurrent dejima or Claude Code
  session, another host process, or you editing the same files by hand
  during the run all land in the same diff and get reported identically -
  the tool has no way to tell them apart.
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

  Both the staging directory and the retained diffs live under
  `$AUDIT_DIR` (`~/.local/share/dejima/audit` by default), never under
  `/tmp`. That is the boundary the whole scheme rests on:
  `docker-compose.yml` mounts nothing covering it, so the container cannot
  read the retained content of earlier runs - `test/static.bats` pins that
  as a regression guard. If the store is configured *inside* the mounted
  workspace it becomes readable and deletable from within the sandbox, so
  in that case no content is retained at all - only a note saying why. A
  session killed with `SIGKILL` (no EXIT trap runs, so no `compare`)
  leaves its staging directory behind; the next run against that
  workspace reaps it, identifying dead owners by pid and process start
  time recorded in an `.owner` file, so a concurrent session against the
  same workspace is never mistaken for dead and disturbed. A directory
  whose owner record is missing or unreadable falls back to a 24-hour age
  check instead of guessing liveness.

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
  the staged side - the size is checked *before* any copy is taken: a file
  the session grew past it withholds with "change too large to retain"
  rather than being copied through `$TMPDIR` first. That ordering is the
  point, not the cap: `compare` runs from the exit trap on every session
  exit and the size is the session's own choice, so copying first would
  let a session turn "I filled my own workspace" into that many bytes
  written to `$TMPDIR` - frequently a tmpfs, i.e. host RAM - at exit, and
  into a whole copy of the file left sitting there if that exit was a
  `SIGKILL`. A generated diff is withheld if it is binary, over 200 lines
  or 64 KiB (and is bounded to that as it is generated, for the same
  reason), or matches a best-effort credential screen - vendor prefixes
  including `sk-ant-`, `sk-proj-`, `ghp_`, `gho_`, `github_pat_`,
  `glpat-`, Slack's `xox[baprs]-`, `AIza`, `AKIA`, `_authToken`,
  `Authorization: Bearer`, and PEM private-key headers, matched
  case-insensitively (deliberately: the one high-value surface this is
  the only net for, `.claude/settings.json`'s `env` block, conventionally
  holds its keys upper-case). That screen is still explicitly best-effort
  and has real false negatives - the denylist above is the reliable half
  of the defence, this is the second net. A git config key holding more
  than one value on either side of the session is not compared at all:
  git resolves such a key to its *last* value in *file* order, and the
  audit does not resolve it - it parses the config files and sorts, so
  lexicographically-last is not the value git will run, and the
  pre-session side is every value the key had rather than one. Comparing
  anyway produced a diff over values git does not use: with two
  pre-session values it read as a deletion that never happened, while the
  value the session actually appended - the one git now executes -
  appeared nowhere in it. That case withholds with "this key has multiple
  values and git uses the last", and must be compared by hand;
  `include.path` is legitimately multi-valued, so this is an ordinary
  shape, not only a planted one. A generated diff can also still come out
  empty - before and after compare equal even though the finding was
  reported as a change - when the config file's *text* changed while the
  parsed value did not, e.g. a value that was re-quoted; that case
  withholds too, saying plainly that the comparison came out empty rather
  than silently showing nothing, since an empty diff for a reported
  change would otherwise read as a bug.

  A per-report **retention budget** (`RETAIN_BUDGET`, 1 MiB) also bounds
  the total diff bytes one report may keep. Once it is spent, remaining
  findings in that report withhold with a note that the budget ran out,
  and both the report and the exit-time stderr summary add an alarm line:
  that many changed host-persistence surfaces in one session is treated
  as a signal in its own right, not merely a limit worth raising - an
  ordinary session changes few enough of these surfaces that the budget
  is never in practice a constraint. `diffs = off` in the config's
  `[audit]` section disables retention (and staging) entirely.

  Two residual limits worth knowing on top of the credential screen's
  false negatives above. The prompt shows at most 40 lines of a diff or
  of new content before truncating, naming the file so you can read the
  rest - a large planted change is truncated exactly where you would most
  want it whole. And the `SIGKILL` case above is a real exposure window,
  not just a cleanup mechanic: until the next run against that workspace
  reaps it, the staging directory sits on disk holding whole pre-session
  file copies (not diffs) of every monitored surface, for as long as the
  workspace goes unused.
- Report findings name a path or config key that a session may itself have
  chosen, so those names reach your terminal as untrusted text. One that
  contains an ASCII control character, a C1 control, or a Unicode bidi
  override - which between them can scroll, blank, or visually reorder what
  you read, and can split a name across the audit's own records - is
  written hex-encoded behind a `{hex}` marker instead, and decodes with
  `printf '%b' "$(sed 's/../\\x&/g' <<< HEX)"`. Ordinary names are printed
  as-is, so the marker appearing at all is itself worth a second look.
  The encoded form is what `dejima-audit ack` records in the baseline, so
  what you acknowledge is the file that is actually on disk rather than a
  readable approximation of its name.
- `~/.claude/projects` (session transcripts and per-project memory) is
  **not** mounted read-only, unlike the code-carrying `~/.claude`
  directories - deliberately. Scoping a read-only mount to "the
  current project's slug"
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
  did) when a write to it is blocked. This is also the sharpest case of
  the time-window caveat above: `~/.claude/projects` is a single
  directory shared by *every* Claude Code session on the host, not scoped
  to the one being audited, so an entirely innocent concurrent session
  working on some unrelated project can produce a `CROSS-PROJECT` finding
  here that reads like the audited session poisoned another project's
  history - it didn't, it just happened to be running at the same time.
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
- Most of what this document asserts is re-checked by the `test/` suite on
  every change - over 300 bats tests across six files, and `runtime.bats`
  builds the image and asserts against a real running container rather than
  a mock: IPv6 blocked, a non-allowlisted domain refused by the DNS proxy
  and a non-allowlisted destination unreachable, `node` unable to re-run
  `init-firewall.sh` to widen the allowlist, no working `sudo`. Coverage is
  not the same as completeness, though. The reasoning in this document is
  judgement rather than assertions, nothing tests it, and a property nobody
  thought to write a test for can still regress quietly. A missing `ipset`
  dedup flag broke firewall startup entirely - twice, on two different
  ipsets - before anyone caught it; there is a test asserting every
  `ipset add` is duplicate-safe now, which is the pattern to expect. Each
  of these tests exists because something was got wrong first.
- The Anthropic OAuth credential (`~/.claude/.credentials.json`) never
  enters the container. It simply isn't mounted: `~/.claude` is not shared
  as a whole (see the mount inventory below), so there is no path from
  inside the container to that file. `dejima` starts a host-side proxy
  (`bin/dejima-anthropic-proxy`) on a per-session unix socket and mounts a
  fake credential in place of the real one - the two secrets are
  placeholders, while `scopes`/`subscriptionType`/`rateLimitTier`/`clientId`
  are copied from the real file so the session's own UI stays accurate. Its
  expiry is set a year out rather than mirrored, deliberately: a near-term
  one would make Claude Code refresh on its own, with a refresh token that
  isn't real, and log the session out. Inside the container,
  `entrypoint.sh` points `api.anthropic.com` at a loopback TLS terminator
  (`anthropic-proxy-forwarder.js`) whose certificate is generated at startup
  and trusted only there, and which pipes raw bytes into the proxy's socket.
  The proxy injects the real access token per request and owns OAuth refresh
  - rotated tokens are written back to the real host file atomically, so
  host-side sessions stay logged in. Claude Code itself is configured
  exactly as it would be on the host: no `ANTHROPIC_BASE_URL`, no
  `ANTHROPIC_AUTH_TOKEN`, nothing that marks the session as unusual to the
  client. The proxy then forwards the client's header block verbatim -
  same names, same casing, same order, repeats intact, and no
  `Accept-Encoding` it didn't send - changing only the `Authorization`
  value, and `anthropic-beta` if the OAuth value isn't already there. Left
  to itself, Python's `http.client` would have rewritten all of that into
  its own house style and moved the fingerprint from the client to the
  wire. What it cannot disguise is that the connection is made by CPython's
  `ssl` rather than by Node: the TLS handshake (JA3/JA4) and the absence of
  connection reuse still distinguish it at that layer. What remains is
  session-scoped: a
  compromised session can still *use* the model API as you while it runs
  (that's inherent to the sandbox working at all), but it can no longer read
  a durable credential and exfiltrate it for offline use via the other
  allowed egress destinations (npm, GitHub, your Gitea host). Caveats:
  `/login` inside the container doesn't work while the proxy is on; the
  refresh flow mirrors a Claude Code internal and may break if upstream
  changes it, in which case the proxy fails loudly (launch abort, 502s on
  API calls) rather than silently; and a 401 that does reach the container
  can make Claude Code clear the fake credential file, showing a logged-out
  session - harmless, since it's a host temp file, and rare, since the proxy
  absorbs 401s with its own refresh-and-retry.
  `[credentials] proxy = off` (in `~/.config/dejima/config`) is the kill
  switch, restoring the previous behavior - the credential mounted into the
  container explicitly, readable by a compromised session. Setups without a
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
- `~/.claude` is **not** shared with the container as a whole. Its contents
  are enumerated in `docker-compose.yml`, in three classes, and anything not
  listed is container-local: writable during the session and gone with the
  container.
  - **Read-write, because it has to survive the session**: `projects/`,
    `file-history/`, `backups/`, `tasks/`, `plans/`, `sessions/`. All
    directories, which is what makes them safe (see the detachment note
    below).
  - **Read-only**: `plugins/`, `hooks/`, `skills/`, `commands/`, `agents/`,
    `output-styles/`, plus the symlink-target directories `dejima`
    discovers at launch. Hooks execute automatically with no separate
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
    `statusline.sh` are mounted read-only at `/etc/dejima-claude/` and
    installed into `~/.claude` by `entrypoint.sh` as root-owned, unwritable
    files. A session can still unlink and replace them - `~/.claude` belongs
    to it - but only its own copy, which was the whole point of making them
    read-only.

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
  files above, and the case that shows why copying beats mounting. It used
  to be bind-mounted read-only onto its own path, which - **confirmed
  against a live container** - blocked replacement only when
  `statusline.sh` was a plain regular file. When it was a symlink (the
  common case, into a config checkout elsewhere), Docker/runc resolved the
  bind-mount destination through the symlink to its target, so the symlink
  entry itself stayed on the writable `~/.claude` mount and remained
  replaceable, and detection was the only compensating control. Staging
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
- DNS resolution itself is allowlisted (see "DNS is allowlisted too" in the
  README),
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
  optional opt-in" above).
- `[core] ssh_key` (see "Headless git push without agent forwarding") is a
  second, independent credential-loading path with the same "signs for any
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
- The sandbox's own user (matching your host user — see "Config parity" in
  the README) has no `sudo`/setuid path back to root once the container is up:
  `entrypoint.sh` runs as root, sets up the firewall directly, then drops to
  that user via `gosu` before execing the configured command (`[core] command`,
  `claude` by default). A compromised session can't
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
  `dejima-project`) a human runs on the host. `dejima`
  warns at launch whenever the resolved store path — default or overridden
  via `DEJIMA_CONFIG_DIR` — lands under the mounted workspace,
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
