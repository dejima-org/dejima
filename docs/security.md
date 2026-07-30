# Security notes

[← dejima README](../README.md)

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
- The sandbox's own user (matching your host user — see "Config parity" in
  the README) has no `sudo`/setuid path back to root once the container is up:
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
