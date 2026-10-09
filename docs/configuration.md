# Configuration

[← dejima README](../README.md)

Day-to-day configuration once dejima is installed and running. The reference
table below is every key there is; the sections after it cover what a project
declares versus what you approve, what carries over from your host, mounts and
scratch space, and what the sandbox knows about itself.

## Configuration reference

Every key dejima reads, its default, and what it is for.

### Two files, and only one of them is yours

`~/.config/dejima/config` is **yours**. dejima reads it and never writes it.
`./install.sh` creates it if you have none, carrying your selection and
anything it could migrate from an older setup, and nothing else.

`~/.config/dejima/defaults.conf` beside it is **dejima's**, and holds every
defaulted key at the value dejima shipped *when this machine first saw that
key*. Your file overrides it; it overrides what the current release would have
chosen.

That second file is why a release cannot move a setting you never chose.
`[core] harness` has no default at all for this reason - a default that could
change later is a config file that is not the source of truth - and this
applies the same argument to every other key. It is not hypothetical: the
`forge` and `workflow` defaults once changed from `gitea`+`worktree-pr` to
`none`+`local-only`, which silently stopped existing sandboxes pushing.

The first launch on a machine writes it and says so once. `./install.sh`
rebuilds it: keys a release added are appended, keys it retired are dropped,
and **every value already in it stays**. When a shipped default no longer
matches your pinned one, `./install.sh` names both and the line that would
take the new one. It does not take it - that is the whole point - and the line
goes in *your* file, never in `defaults.conf`, which the next rebuild rewrites.

Do not edit `defaults.conf`. Anything in it that dejima no longer understands
is skipped rather than refused, since you are not the one who put it there, and
a launch tells you to re-run `./install.sh`.

`dejima --print-config` prints every key as it resolves. Which of the three
answered is readable from the files themselves: in `config` it is yours, in
`defaults.conf` it is pinned, in neither it is what this release ships.

**`required` in the Default column is what you have to set yourself**, and it
is exactly the set with no line in `defaults.conf`: a key with no default has
nothing to pin. Exactly one is required unconditionally - `[core] harness`.
Every other `required` is conditional on a selection you made, and each table
below says which; a section belonging to something you did not select is never
read, so its required keys are not yours to fill in.

Every tool takes `--help`, which describes its own arguments and what they do.
That is the fastest answer to "what does this flag mean"; this page is for the
config file behind them.

### `[core]` - what this sandbox runs

The three selections come first because everything below depends on them: the
harness decides which `[harness.<name>]` section is read, and the forge decides
which `[forge.<name>]`.

| Key | Default | Purpose |
| --- | --- | --- |
| `harness` | **required** | agent harness the container runs; refused if unset, so a later default cannot change your selection. Also settable per launch with `--harness`, which is how a host keeps one harness as its default and reaches another when it wants to |
| `forge` | `none` | forge integration: `gitea` (`gitea-pr`/`gitea-issue`), `github` (`gh`/`github-pr`, opens `ssh.github.com:22` for push), or `none` (no forge at all) |
| `workflow` | `local-only` | workflow the session briefing tells the agent to follow: `worktree-pr` (push + open a PR), `branch-push` (push, stop at the branch), or `local-only` (commit locally, push nothing) |
| `identity` | unset | which `[identity.<name>]` section supplies the credentials and git name this session acts under; also settable per launch with `--identity`, which is how one host runs a session per account. Unset selects `[identity.default]` where the config has one. A name with no section is refused rather than falling back |
| `command` | *(the selected harness's own)* | container's main process (e.g. `nvim`), also settable per launch with `--cmd`. Overriding it changes what dejima launches, not which harness is wrapped |
| `tools` | unset | optional tools to put in the image, colon-separated; also `.dejima/tools` in a project (approved first) and `--include` per launch. None by default. See [docs/tools.md](tools.md) |
| `firewall` | `on` | egress firewall; `off` disables it (debugging only), also settable per launch with `--no-firewall` |
| `internal_domains` | unset | approved domains that really do resolve inside your own network, colon-separated. The policy refuses an answer for a permitted name that points at a private address, because an answer decides what the allowlist contains and comes from outside; this exempts the ones you know are internal. It exempts only - a name here is not reachable unless it is also approved, and naming one that is not stops the launch saying so. The configured forge, the Loki host and a self-served backend's `base_url` host are permitted and exempt already, so this is for destinations dejima does not configure itself. `dejima-allow` reads this same key when adding a domain to a running session |
| `share_dir` | `~/.local/share/dejima/shared` | host-visible read/write scratch dir. One directory per project underneath it, and only that project's is mounted at `~/shared`. `dejima-share` is the host side of it |
| `known_hosts` | `~/.ssh/known_hosts` | known-hosts file used for git-over-ssh |
| `update_check` | `on` | at startup, say when this checkout is behind the branch it tracks. One `ls-remote` to your own remote, at most hourly, never fetching; `off` makes dejima contact nothing of its own accord. The answer is cached in `~/.local/share/dejima/update-check`, which is safe to delete |
| `ssh_key` | unset | **deprecated** - the pre-identity spelling of `[identity.default] ssh_key`. Still read when the config has no `[identity.default]`; refused when it has one, since the two say the same thing |

**No forge is the default**: `[core] forge = none` with
`[core] workflow = local-only`, so the sandbox works locally and pushes
nowhere. Every other workflow needs forge credentials, which is what you are
opting into when you pick one.

### `[harness.<name>]` - the harness you selected

One section per harness, and only the one `[core] harness` names is read. Each
ships its own keys; see [providers.md](providers.md) for the manifest contract
behind them.

#### `[harness.claude-code]`

| Key | Default | Purpose |
| --- | --- | --- |
| `backend` | **required** | which model API this harness talks to, and so which credential the proxy injects. A directory under `backends/`, each shipping its own `[backend.<name>]` keys. Per harness rather than global, because running Claude Code against Anthropic and Cline against something else is the ordinary case. No default, for the reason `[core] harness` has none: one that could change later would move a session to another endpoint without its config changing. Unset, dejima writes `anthropic` into your config once and says so - a migration rather than a default, so nothing it decides later can move you. Also settable per launch with `--backend`. See [providers.md](providers.md#model-backends) |
| `projects_dir` | `~/.claude/projects` | where Claude Code session transcripts live |
| `file_history_dir` | `~/.claude/file-history` | Claude Code's edit-undo record, mounted per session rather than whole |
| `statusline_path` | `~/.claude/statusline.sh` | statusline script path |

#### `[harness.cline]`

| Key | Default | Purpose |
| --- | --- | --- |
| `backend` | **required** | as above, and the risk is concrete here: Cline supports many backends and has one of its own. Nothing is written into your config for you either, unlike Claude Code: there is no one endpoint every existing Cline session was already using, so any value dejima recorded would be a guess. Also settable per launch with `--backend` |
| `model` | **required** | model id the endpoint serves, exactly as that endpoint spells it - a hosted catalogue namespaces by vendor (`z-ai/glm-5.3`) and may qualify a variant (`deepseek/deepseek-r1:free`). No default, because any shipped one goes stale with the next Cline release. Also settable per launch with `--model` |
| `context_window` | unset | tokens Cline may use before compacting. Needed for a model it has no catalogue entry for, which is every self-served one. Also settable per launch with `--context-window` |
| `state_dir` | `~/.local/share/dejima/cline` | per-project Cline state; one directory per workspace |

### `[backend.<name>]` - the model API you selected

One section per backend, and only the one your harness's `backend` names is
read. `proxy` is available in every one of them; the rest are that backend's
own. See [providers.md](providers.md#model-backends) for how much use each has
actually had.

| Key | Default | Purpose |
| --- | --- | --- |
| `[backend.<name>] proxy` | *(inherits `[credentials] proxy`)* | whether the credential proxy runs for this backend. Per backend so that one backend the proxy cannot serve is not a reason to stop withholding credentials from the ones it can. Off means this backend's real credential is given to the session, and dejima says so at launch |
| `[backend.anthropic] credential_file` | `~/.claude/.credentials.json` | the host file this backend's credential is read from, per request. A path, never a secret, and never mounted into the container |
| `[backend.anthropic-api-key] credential_file` | `~/.claude.json` | where your Anthropic API key is. Defaulted to where Claude Code's console login puts it, so the common case needs nothing set; point it at a file of your own if you hold the key yourself. Read host-side per request and never mounted, and the key is stripped from the copy of `~/.claude.json` dejima stages |
| `[backend.anthropic-api-key] credential_field` | `primaryApiKey` | which value inside that file is the key, as dot-separated object names. Clear it (`credential_field =`) when the file is nothing but the key |
| `[backend.openrouter] credential_file` | **required** | your OpenRouter API key, in a file. Read host-side per request and never mounted; the container only ever holds a placeholder. No default, because a key's location is yours and guessing at one would point dejima at a file it has no reason to think exists |
| `[backend.self-hosted] base_url` | **required** | where you serve the model. A loopback or RFC 1918 address, or a host you have allowlisted - it has to be an endpoint needing no credential, since there is none to withhold. On the backend rather than the harness, so a local endpoint stays configured while a hosted API is selected |

### `[credentials]` - how the credential is withheld

| Key | Default | Purpose |
| --- | --- | --- |
| `proxy` | `on` | host-side credential proxy; `off` mounts the real credential into the container directly. Overridable per backend with `[backend.<name>] proxy` |
| `transport` | `tls` | set to `loopback` to fall back to a plaintext forwarder with an explicit base URL, keeping the credential out of the container but reinstating the base-URL fingerprint: for when certificate pinning breaks the default TLS path (see [security notes](security.md)) |

### `[identity.<name>]` - who the session acts as

Groups the SSH key, the git name and the forge credential belonging to one
account, so a host can run a session per account. Selected by `[core]
identity`, or `[identity.default]` when that is unset. Nothing here is
required: an identity supplies what it names and no more.

| Key | Default | Purpose |
| --- | --- | --- |
| `ssh_key` | unset | the SSH key this identity pushes with |
| `user_name` | unset | `user.name` for commits made in the session |
| `user_email` | unset | `user.email` for commits made in the session |
| `token_file` | *(the forge's own default)* | this identity's Gitea/Forgejo API token, overriding `[forge.gitea] token_file`. Read only when `[core] forge = gitea` |
| `push_token_file` | unset | this identity's write-capable GitHub PAT, overriding `[forge.github] push_token_file`. Read only when `[core] forge = github` |

See [Identities](#identities) below for the worked examples.

### `[forge.<name>]` and `[github]` - forge credentials

Only the section `[core] forge` names is read. `[github]` is separate from
`[forge.github]` on purpose: the first is read access to GitHub whichever forge
you selected, the second is push access when GitHub *is* your forge.

| Key | Default | Purpose |
| --- | --- | --- |
| `[forge.gitea] ssh_host` | **required** for `forge = gitea` | Gitea/Forgejo SSH hostname |
| `[forge.gitea] api` | **required** for `forge = gitea` | `https://<gitea host>/api/v1` |
| `[forge.gitea] token_file` | `~/.config/gitea/token` | path to the Gitea/Forgejo API token (the file, not the token itself) |
| `[forge.github] push_token_file` | unset | path to a **write-capable** PAT, used only when `[core] forge = github`: deliberately separate from `[github] token_file`; see "GitHub push" in [docs/security.md](security.md) |
| `[github] token_file` | `~/.config/gh/sandbox-token` | path to a read-only PAT for private GitHub repos / `gh`, and it should stay read-only. Read for every session EXCEPT when `[core] forge = github` and `push_token_file` is set: both fill `GH_TOKEN`, the forge's wins, and the launch says so. Which token can push is the half that matters |

### `[mounts]` - extra host paths

| Key | Default | Purpose |
| --- | --- | --- |
| `readonly` | unset | extra host paths (colon-separated) a personal config needs, mounted read-only at their own path |
| `read_write` | unset | host paths (colon-separated) mounted **read-write** at their own path: for directories meant to outlive the session and be shared by every project; refused if they overlap anything dejima needs out of a session's reach |
| `read_write_per_project` | unset | the same, mounted at the path named but backed by `<path>/projects/<slug>` - one directory per project rather than one for the host. For anything a session writes to be read later as background, where another project reading it would be a channel rather than a convenience |
| `nvim_config` | unset | nvim config dir, used when `[core] command = nvim` |

### `[audit]` - the exit-time audit

| Key | Default | Purpose |
| --- | --- | --- |
| `dir` | `~/.local/share/dejima/audit` | where exit-time audit findings are stored |
| `baselines_dir` | `~/.local/share/dejima/baselines` | where audit baselines are stored |
| `keep` | `10` | how many past findings/baselines to retain |
| `diffs` | `on` | keep the diff of what changed alongside each finding; `off` records that something changed without retaining the content |
| `strict` | `off` | refuse a headless (non-tty) launch over unacknowledged CRITICAL findings; also settable per launch with `--strict-audit` |

### `[epitaph]` - what a compacted session leaves behind

| Key | Default | Purpose |
| --- | --- | --- |
| `enabled` | `on` | keep the summary a harness writes when a session compacts; `--no-epitaph` skips it for one launch |
| `dir` | `~/.local/share/dejima/epitaphs` | where they are kept; never mounted into a container |
| `loki` | `off` | also push each epitaph to `[logging] loki_url`, host-side |

### `[logging]` - shipping logs off the host

Off entirely until `loki_url` is set. Nothing leaves the machine otherwise,
and there is no endpoint of dejima's own anywhere in this.

| Key | Default | Purpose |
| --- | --- | --- |
| `loki_url` | unset | ship DNS/firewall logs to a Loki endpoint; `--no-log` clears it for one launch, which silences everything downstream of it |
| `conversation` | `off` | opt-in: also ship session transcripts to Loki (needs `loki_url`); see "Conversation logging (opt-in)" in [docs/security.md](security.md). `--no-conversation` turns it off for one launch, and `--no-log` implies it |

### `[remote-access]` - the web front door

Off entirely until `enabled` is `on`. The `ttyd_*` keys configure the terminal
page and are read once at process start, so editing them needs
`systemctl --user restart dejima-ttyd.service`. See
[docs/remote-access.md](remote-access.md).

| Key | Default | Purpose |
| --- | --- | --- |
| `enabled` | `off` | the switch: nothing else here runs until this is `on` |
| `ntfy_url` | **required** for notifications | ntfy topic URL for session notifications. `dejima-notify-watch` refuses to start without it; nothing else reads it |
| `base_url` | unset | public URL of the web front door, for the notification's deep link. Absent, pushes still go out - just with no link on them |
| `debounce` | `60` | seconds between repeat notifications for the same session |
| `ttyd_port` | `7681` | loopback port `ttyd` listens on; the reverse proxy has to `proxy_pass` to the same one |
| `ttyd_font_size` | unset | terminal font size in px, 8-72. Applies to every client, phone and desktop alike |
| `ttyd_tmux_prefix` | unset | the tmux prefix the page's buttons send; the page assumes stock `C-b` without it |
| `ttyd_focus_on_tap` | unset | `on` lets a tap on the terminal raise the phone keyboard; unset means only the KBD button does |
| `ttyd_button_colors` | unset | `off` returns the toolbar to monochrome |

### `[ui]` - what a launch prints

| Key | Default | Purpose |
| --- | --- | --- |
| `banner` | `on` | the three-line summary at the top of a launch - project and branch, the selection, and the switches whose state changes what a session can do. `off` prints nothing. Never drawn when output is redirected |


## Global and per-project domains and dependencies

Allowed domains and dependencies each stack through their own layers. The
layers **add** to each other, so a narrower layer can only widen what a broader
one already permits: the set a session gets is the union of every layer that
applies to it, never an override of one by another. Nothing at the project
layer can withdraw a built-in domain, and nothing at the container layer can
withdraw a project one.

| Config | Layers, least specific first |
| --- | --- |
| Allowed domains | built-in → global → project → container (one session) |
| Dependencies | base image → global → project |

Dependencies have no container-only scope: installing one always needs an
image rebuild, so there's no `dejima-allow`-style live-session patch
for them.

A project can declare what it needs in two committed files:

```
.dejima/allowed-domains    # one domain per line, fully qualified
.dejima/dependencies       # <apt|npm|pip|cargo>:<name> per line, or a
                           # tarball:<name>@<sha256>:<url> release archive
```

A domain has to name at least two labels. A permitted name covers everything
under it, because the sandbox's resolver is configured per name and matches the
name and its subdomains, with no exact-name form to use instead - so a bare
label would grant its whole suffix, and `org` would ask for every `.org` name.
The same floor applies to every key whose value becomes a permitted
destination: `[core] internal_domains`, a forge's `ssh_host` and `api`, a
backend's `base_url`, and `[logging] loki_url`. A value that is not a host name of at least two labels is
refused when the entry is declared and again at launch, naming the key it came
from - which includes a value that reached the launcher through a URL and lost
its host on the way, such as a `loki_url` carrying userinfo.

An approval granted before this rule existed is still read rather than called
corrupt, so an upgrade does not present as tampering; the launch stops instead,
naming the entry. There is no `remove` verb, so clearing one means editing the
store by hand - `~/.config/dejima/allowed-domains` for a global approval, or
`~/.config/dejima/projects/<slug>/allowed-domains` for a project's.

**Declaring grants nothing.** The project directory is bind-mounted
read-write, so a session could write these files; they are read only to
compare against reality and suggest a command. Approvals live outside the
container under `~/.config/dejima/` (`$DEJIMA_CONFIG_DIR` relocates the
tree) - global at its root, per project under `projects/<slug>/` - written
only by tools you run on the host:

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

The declaration those two write still grants nothing, and writing to it does
not promote it. That it is session-writable is exactly why both tools refuse to
write a `.dejima` directory or a `.dejima/<kind>` file that is a **symlink**.
The refusal is the `open` itself rather than a check before it, so it holds even
against a session still running while you type the command - see
[Declaration files are session-writable](security.md#declaration-files-are-session-writable).
The same write reads the file back to skip an already-declared entry, and that
read is capped, since a session can make its own `.dejima/<kind>` arbitrarily
large for free.

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

Approved domains join the allowlist at the next launch. `dejima-allow` can also
patch a running session immediately, but only when run bare or with
`--container` - approving here (`--project`/`--global`) never touches one; see
[Adding a domain to a running session](security.md#adding-a-domain-to-a-running-session).
A domain that resolves to a private address has no live patch at all. Approved
dependencies are baked into a derived image built `FROM` the shared base -
first `dejima:<username>-global` if the global store has any dependency
approved, then `dejima:<username>-<slug>` on top of that if the project store
does - so they take effect on the **next** launch. Because of that rebuild, the
usual moment to approve is *after* leaving the sandbox, and persistence never
requires a running container.

`dejima-project approve` never attempts to patch a running session: it only
ever calls `dejima-allow` without `--container`. If an individual approval
can't be recorded - an unwritable store, a slug collision, a corrupt approval
list - it reports that entry as not approved and keeps going, so one bad entry
can't cost you the rest of the set. It then exits non-zero if anything failed,
so `dejima-project approve ~/myproject && dejima` won't launch a session
missing the approvals you just confirmed.

A session whose project declares something it doesn't have is told so in its
startup context, with the exact command to hand you. Project approvals are
inherited by subdirectories, so a git worktree under the project gets its
parent's; global approvals apply everywhere regardless.

### Tarball dependencies

For a toolchain no package ecosystem ships in a version you can use - a
current Go, say, where Debian's is several releases behind - a dependency can
name a release archive instead:

```sh
dejima-dep add --global tarball:go@<sha256>:https://go.dev/dl/go1.25.0.linux-amd64.tar.gz
```

Fetch the archive on the host and hash it. Do not take the digest from the
same page that serves the download unless you trust that page for both:

```sh
curl -fLO https://go.dev/dl/go1.25.0.linux-amd64.tar.gz
sha256sum go1.25.0.linux-amd64.tar.gz
```

Where a project publishes a checksums file or signs its releases, verifying
against that beats hashing whatever arrived: it says the archive is the one
the project published, not the one your connection received.

It unpacks with `--strip-components=1` into `/opt/dejima/<name>`, and
`/opt/dejima/<name>/bin` goes on `PATH` - one convention covering the usual
shapes without layout options, since a Go archive is under `go/` and an nvim
release under `nvim-linux-<arch>/`. Compression is detected, so `.tar.gz`,
`.tar.xz` and `.tar.zst` all work.

**The digest is mandatory** and is checked before anything is unpacked.
Without one you would approve a *name* whose contents the far end can change
afterwards. Two consequences:

- **A tarball dependency locks the project to one architecture**, because a
  digest does. A package name resolves per-host and a digest cannot: it names
  one archive, built for one architecture. There is no per-architecture
  tarball spec today, so a project that declares one is a project that builds
  on machines of that architecture and no others. Track that at
  [#97](https://gitbox.branderson.io/dejima/dejima/issues/97).
- **Upgrading is an approval, not a version bump.** A new release is a new
  digest, so it goes through `dejima-dep add` and `dejima-project approve`
  again. That is the mechanism working, not friction to route around.

The URL's character set is deliberately narrower than URLs allow: the spec is
interpolated into a `RUN` line that runs as root at build time, so anything
shell-active is refused outright rather than quoted around, and only `https`
is accepted.

### Declaring that the history is evidence

A third file, approved the same way as the two above:

```
.dejima/corpus             # one rule per line; today, commit-per-step
```

An approved `commit-per-step` adds a paragraph to the session briefing
requiring **one commit per plan step that writes a file**, rather than one
commit per task, and explaining why. Absent or unapproved, nothing is added
and nothing changes, which is the default for every project that has not asked
for it.

It goes through approval despite granting no capability, and that is
deliberate. `.dejima/` lives in the workspace, which is session-writable, so a
session able to turn this on by writing a file would be writing the *next*
session's system prompt. `bin/dejima` reads the approval store and never a
project's declarations - a static test holds that it does not so much as name
that directory.

An unknown rule is reported but never offered for approval. One that nothing
implements would approve cleanly, sit in the store and do nothing, which reads
as being in force when it is not.

The reason is recoverability rather than tidiness. A step is legible afterwards
only if the file's state immediately before and immediately after it can both
be read back: before from the commit's parent, after from the commit. One
commit carrying several steps that touch the same file destroys that, and
nothing recovers it later, so it has to be recorded while the work happens.

**Check the forge's merge policy before relying on this.** The setting that can
undo all of it is yours. A squash-merge is survivable, because the step commits
stay reachable through the branch ref, but "delete branch on merge" - which
several forges offer and some default on - removes the last thing pointing at
them. Measured both ways on a throwaway repository: squash-merge with the
branch retained left every step commit reachable in a fresh clone; the same
merge with the branch deleted first left none. So a project can adopt the rule,
write every plan correctly, and still yield nothing, with no error anywhere.
dejima's own history is intact because it merges with merge commits.

It lives in the project rather than in `~/.config/dejima/config` because it is
a fact about the repository: anyone who clones it gets the same commit
discipline, and a rule half the contributors follow produces a history nothing
can be taken from. What dejima does not do is say what the history is *for*.
Collecting it is the operator's business; the briefing states the rule the
project adopted and stops there.

## Config parity with your host agent harness setup

What carries over from your host into the container, and what deliberately
does not. The mechanism is the same whichever harness `[core] harness`
selects; the specific paths below are per harness, and the two shipped ones
differ more than the mechanism does.

### Claude Code

Global `CLAUDE.md`, settings, hooks, skills, and plugins all carry over
automatically, and your existing login stays effective too - no separate
first-run login, though the credential itself never enters the container
(see [security notes](security.md) for the host-side proxy that makes
that work).

Plugins carry over in two pieces, because they are two different things. What
Claude Code rewrites as it runs - the installed-plugin registry, the resolved
catalogue, the marketplace checkout - is copied in as a **writable** copy, so
the session can install or refresh a plugin without reaching your files. Each
already-installed version under `plugins/cache/` is mounted **read-only**
instead: it is the bulk of the tree, and an update writes a new version
directory beside the old rather than changing it.

That split is why a plugin update now works inside a session. The whole tree
used to be mounted read-only, which meant Claude Code could neither materialise
the new version nor record it, and the plugin was left at a version the
catalogue no longer matched - which presents as the plugin simply not loading.
The fix was not to make your files writable: nothing the session writes reaches
them either way, because what it writes is a copy.

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

### Cline

Your own configuration carries over the same way Claude Code's does - the
table under [What comes in from your host](#what-comes-in-from-your-host) is
the list. Your *sessions* do not, and that is the design rather than a gap.

Cline keeps one `sessions.db` indexing every session it has ever run, with
the project a session belonged to as a field inside the record rather than a
directory above it. There is no per-project slice of your `~/.cline/data` to
mount, so mounting it at all would put every project's transcripts into every
session. dejima instead gives each workspace its own Cline data directory
under `[harness.cline] state_dir` (default `~/.local/share/dejima/cline`),
mounted at `~/.cline/data` in the container. Sessions persist across runs of
the same project and are invisible to every other project.

Because that directory is dejima's rather than yours, resuming on the host is
not a supported path - see
[Sessions, and where they live](#sessions-and-where-they-live) below. Relaunch
dejima on the same project instead, which is what the briefing tells the
session to offer.

The model configuration is written fresh by dejima at each launch and is not
yours either. Where the model is comes from `[harness.cline] backend` and
nowhere else, so there is no second setting for it to disagree with, and two
shapes are supported:

- **A backend the proxy serves** (`anthropic`, `anthropic-api-key`,
  `openrouter`) - reached through dejima's own credential proxy exactly as
  Claude Code is. What is written into the container is the placeholder
  `sandbox-credential-proxy-placeholder` and the endpoint's real hostname; the
  credential stays on the host. Which of Cline's own provider types dejima
  writes comes from the backend's `api_style`: its native Anthropic client for
  one, its OpenAI-compatible client for the other.
- **A backend with no credential** (`self-hosted`, carrying its own
  `[backend.self-hosted] base_url`) - a model you serve, at either a loopback
  or RFC 1918 address or a host you have allowlisted with `dejima-allow`.
  Nothing needs a credential, so there is nothing to withhold.

Keeping the address on the backend rather than on the harness is what lets you
have a local model and a hosted API both configured and switch between them by
changing one word.

A name qualifies through the allowlist rather than through how it is spelled,
because that is the same store deciding whether the container can reach the
endpoint at all: one that fails the check is one the session could not have
connected to anyway. A model server on your own network normally has a name,
so requiring a literal address would have made this path unusable for the
ordinary case.

Anything else is refused at launch - a hosted API pointed at through a
no-credential backend would want its key inside the container, and dejima has
no proxy that could hold one back on its behalf. Note what the check is *not*
doing: dejima writes a placeholder into the container on the proxied path
whatever the endpoint is, so no real credential enters it either way. What the
check decides is whether the configuration can work at all, which is worth
saying at launch rather than as an auth error three layers down. See
[development.md](development.md#worked-example-cline).

If the endpoint serves a model Cline has no catalogue entry for - which is every
model you serve yourself - Cline has no context budget for it either, and will
grow the conversation until the *server* rejects it rather than compacting:

```
rpc error: ... request (16465 tokens) exceeds the available context size (16384 tokens)
```

Set `[harness.cline] context_window` to stop that. With it, Cline compacts
before it reaches the limit instead of overflowing.

Set it a little **under** whatever the server allows. Cline's accounting is
approximate, and a compaction does not always land under target when a single
tool result is large, so a value equal to the server's limit still overflows
occasionally. There is no default: the right number belongs to the model being
served, and a wrong one is worse than none - too high changes nothing, too low
compacts constantly.

`[harness.cline] model` has no default and must be set. Any model id shipped
here would go stale with the next Cline release, and choosing the model an
unattended agent runs on is yours to make.

Cline's CLI needs a CPU with AVX2. It is a Bun-embedded compiled binary and
Bun's default build requires it, so a VM whose CPU model is `x86-64-v2-AES`
gets SIGILL before printing anything. `x86-64-v3` or better works.

Caveat: MCP servers or hooks that shell out to host-specific binaries (a
browser, a language runtime not installed here) will not work until that
tooling is installed in the image. Add it with `dejima-dep` rather than by
editing the base `Dockerfile`: a dependency added that way is declared,
approved and layered like any other, and it survives a rebuild. Editing the
Dockerfile directly puts it outside that record.


#### Sessions, and where they live

This project's Cline state - sessions, transcripts, tasks - is kept on the host
in `~/.local/share/dejima/cline/<project>` and mounted at `~/.cline/data`. It
survives the container being replaced, so **launching dejima again on the same
project picks up where the last session left off.**

A directory per project rather than one shared: Cline indexes every session it
has ever run in a single database, so sharing one would put every project's
history in every project's context - the same boundary `~/.claude/projects`
gets, for the same reason.

**Cline sessions are not importable or exportable.** A session started by
running `cline` on your own machine is in `~/.cline/data` and is not visible
inside dejima; a session started inside dejima is in the per-project directory
and is not offered back to a host-side Cline. There is no import, no export,
and no merge - see
[#301](https://gitbox.branderson.io/dejima/dejima/issues/301) for why that was
looked at and not built.

The session briefing tells a Cline agent this, so it will not offer to hand
you a session to resume outside the sandbox. Claude Code can be resumed on the
host and its briefing says so; the claim lives in each harness's own briefing
fragment rather than in the shared preamble, because only one of them can make
it.

#### What comes in from your host

The same shape as Claude Code's, and for the same reason: your own
configuration should reach a session, and nothing the session writes should
reach your machine.

| Host path | How it arrives | Why |
| --- | --- | --- |
| `~/.agents/skills/` | read-only mount | skills are instructions the agent follows |
| `~/.agents/hooks/`, `~/.cline/hooks/` | read-only mount | hooks are programs cline runs |
| `~/.agents/AGENTS.md` | read-only copy | instructions; a copy also survives it being a symlink into a dotfiles checkout |
| `~/.agents/rules/*.md`, `*.txt` | read-only copy, into `Documents/Cline/Rules/` | see below |
| `~/Documents/Cline/Rules/*.md`, `*.txt` | read-only copy | the location cline actually reads |
| `~/.cline/settings.json`, `~/.cline/cline_mcp_settings.json` | writable copy, discarded | cline rewrites both as it runs |
| `~/.cline/data/` | this project's own state directory | see above |

Read-only is the point rather than caution. A session that could rewrite a
hook, a skill or an MCP server definition would be choosing what happens on
**your** machine the next time you start cline outside a container - which is
persistence for a prompt injection, in files nobody re-reads before the next
run. The two settings files are copies rather than read-only mounts because
cline rewrites them itself; the copy is discarded with the container.

The read-only directories are scanned for symlinks, so a `skills/` that is a
link into a dotfiles checkout brings its target too. dejima refuses a target
that overlaps one of its own guarded stores.

**Global rules come from two places and land in one.** cline loads them from
`~/Documents/Cline/Rules` and nowhere else - `~/.agents/rules` reads like the
obvious companion to `~/.agents/skills` and is not loaded, which you can see
by planting a file in each and opening `cline config`. So dejima copies the
files from *both* host locations into the one directory cline reads, rather
than mounting `~/.agents/rules` where nothing would look at it.

They are copied file by file rather than mounted as a directory, because
dejima writes its own briefing into that same directory and a read-only mount
over it would leave nowhere to put it.

Two collisions have fixed answers. A name present in **both** host locations
is taken from `Documents/Cline/Rules`, since that is cline's own location for
rules and where it writes when you edit them through cline. A host file named
`00-dejima.md` is skipped: that is the briefing's name, and dejima's wins.
## What dejima says before it starts

Some launches print a notice first: an environment variable that is no longer
read, a deprecated key, a guard that is not registered, a line dejima wrote
into your config. Everything after that is the image build, which on a cold
cache is thousands of lines - so when a notice was printed, dejima waits for
Enter before starting it.

The wait happens only when there was something to read, and only when a
terminal is attached. An unattended launch never blocks on it.

`--no-pause` skips the wait and still prints the notice. It is for starting
several sessions at once - a tmuxinator layout, a script - where every one of
them has a terminal and none of them wants a keypress. It is a flag rather
than a config key on purpose: it describes the terminal in front of one
launch, not a standing preference.

A long list of entries left in the shared directory is sampled rather than
printed whole, for the same reason: it is a standing condition you clear once,
and it should not push the things about this run off the screen.

## Identities

**Several accounts on one machine, and none of them yours.** An
`[identity.<name>]` section groups what one session acts as - the SSH key, the
forge token, the name on the commits - so that pointing a launch at a
different account is one word rather than four edits.

The rest of these documents ask you to give a session an account of its own -
the README under [Using this responsibly](../README.md#using-this-responsibly),
and security.md's [Give the sandbox its own
identity](security.md#give-the-sandbox-its-own-identity). This is how you
have more than one of them, which you will: an account is scoped to what it
may reach, and one account scoped to everything any session might ever need
is the thing separate accounts existed to avoid.

So the sections are per **agent account**, not per person:

```ini
# Pushes to the gitea forge, and can reach nothing on GitHub.
[identity.agent-gitea]
ssh_key    = ~/.ssh/id_agent_gitea
user_name  = dejima agent (gitea)
user_email = agent-gitea@example.invalid
token_file = ~/.config/gitea/agent-token

# A GitHub account, with push rights to the repositories this host works on.
[identity.agent-github]
ssh_key         = ~/.ssh/id_agent_github
user_name       = dejima agent (github)
user_email      = agent-github@example.invalid
push_token_file = ~/.config/gh/agent-push

# A second GitHub account, for a repository the one above may not touch.
[identity.agent-vendor]
ssh_key         = ~/.ssh/id_agent_vendor
user_name       = dejima agent (vendor)
user_email      = agent-vendor@example.invalid
push_token_file = ~/.config/gh/vendor-push
```

Select one with `[core] identity = agent-gitea`, or per launch with
`--identity agent-github` - which is how one host runs a session against each
of these at the same time, each pushing as itself.

**The separation is the point.** Three accounts means three things you can
scope, revoke and read in a log independently: a session that turns out to
have been prompt-injected reached what its own account could reach, and
answering "what did it touch" does not start with "everything I can touch".

**What an identity may set** is deliberately narrow: `ssh_key`, `user_name`,
`user_email`, and whichever keys the forges declare as an account's. A forge
says which of its own keys those are (`identity_keys` in its manifest), so
`token_file` belongs to an identity on the gitea path and `push_token_file`
does on the GitHub one, and neither is a list core keeps its own copy of.

**`default` is the account a session gets when none is named.** With `[core]
identity` unset, an `[identity.default]` section is what a launch acts under -
the ordinary account, given a name so it can carry the git name and the forge
credential too.

**`[core] ssh_key` is that key under its old name, and is deprecated.** A
config with no `[identity.default]` reads it as before; a config with both is
refused rather than ranked, because which key a session pushed with should not
depend on precedence rules. Every launch that sets it says so and prints the
section to move it into - including launches running as some other identity,
which are one `[identity.default]` away from that refusal.

**A credential does not fall through.** An identity that names some and leaves
the rest to the section beneath it is refused, naming each one: an identity is
how one session's account stays separate from another's. "Set" means written
in the file, so a forge key carrying a schema default - `[forge.gitea]
token_file` - still answers for an identity that names none.

**A name with no section is refused.** `[core] identity = agent-gihub` does not
quietly use this machine's own credentials - it stops the launch and says so.
Pushing under the wrong key fails loudly; pushing under your default key when
you asked for another one does not fail at all, which is the direction worth
being careful about.

**`user_name` and `user_email` reach the container's git config**, appended to
the copy dejima already makes of your `~/.gitconfig`. Your real one is not
touched, which was already true and is what the copy exists for.

**Selection is the host's, not the project's.** There is no `.dejima/` kind
for an identity and a project cannot name one: a project's `.dejima/` is
committed and shared with everyone working on it, and both the credential and
which account this host holds are that host's own. `[core] identity` and
`--identity` are the whole of it today.

A project-side layer would be a different thing than it sounds - not "this
project's credentials", which cannot be shared, but "this project wants
whichever account you have called X". That does not exist yet, and this
document will say so until it does.

## Headless git push without agent forwarding

**The reason to do this is identity, not uptime.** A forwarded agent
authenticates the session **as you**: every commit and every pull request it
produces is yours, and for as long as it runs it can reach whatever that key
can reach. A key of its own, belonging to an account that is not you, gives
the session an identity you can scope, revoke and read in a log separately
from your own. See
[To your forge, the sandbox is you](security.md#to-your-forge-the-sandbox-is-you)
for why that matters more than it first appears.

Running unattended is the second reason and the lesser one. Agent forwarding
ties SSH access to whichever client is currently connected, so it dies when
that client disconnects and takes git-over-ssh with it for anything still
running headless.

Either way, generate a dedicated, purpose-built keypair:

```sh
ssh-keygen -t ed25519 -N '' -f ~/.ssh/dejima_ed25519
```

Passphrase-less is deliberate - this is meant to be a low-privilege
credential living only inside the container, not your personal identity. Add
the public half as a Gitea deploy key scoped to just the repos that need
push access, then set it in the config:

```
[identity.default]
ssh_key = ~/.ssh/dejima_ed25519
```

`entrypoint.sh` loads it into a container-local `ssh-agent` at startup and
deletes the plaintext copy immediately after - the sandbox user itself never
has a path to the raw key, only the agent socket (see
[security notes](security.md) for the full mount rationale).

Setting it means a forwarded agent is not merely unnecessary but **not
mounted**: your own `SSH_AUTH_SOCK` is not passed to the container at all, so
nothing in a session can sign with your personal identities by naming the
socket directly. That is the point of choosing a dedicated key, and it is worth
knowing before you choose one - a session that also needed the forwarded agent
for something else (a second remote, a private submodule over ssh) no longer
has it. Leave this unset to keep the agent.

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

The lockfile is layered on as a **copy**, not as your file: `bin/dejima`
mounts a `mktemp` duplicate and deletes it afterwards, so a plugin sync
inside a session cannot rewrite the host's `lazy-lock.json`.

`~/.local/share/nvim` (plugin source and `mason/` binaries), `~/.local/state/
nvim` and `~/.cache/nvim` are **Docker volumes, not host directories**. Your
own nvim data is never mounted, so nothing a session installs can reach the
editor you run outside the container. They do persist across containers,
which is what stops every launch from reinstalling plugins - so they are
named per project. Under one shared name, a session that wrote a Lua file
under `lazy/`, or replaced a binary under `mason/bin/`, would leave something
the next session in an *unrelated* project executed. Nothing there is
protection against a session tampering with its own project's plugins, which
it can do freely and which only ever runs inside the sandbox.

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
read_write = ~/.cache/shared-toolchain
```

`[mounts] read_write_per_project` mounts at the same path, but backs it with
one directory per project instead of the whole thing:

```
[mounts]
read_write_per_project = ~/specs
```

The container sees `~/specs` either way. Behind it, `read_write` puts the
directory itself - every session's contents, including other projects' - and
`read_write_per_project` puts `~/specs/projects/<slug>`, keyed the same way
`[core] share_dir` and the audit store are.

**Which to reach for is decided by one question: should another project's
session read what this one leaves there?** For a build cache or a directory of
scripts, yes, and `read_write` is right. For design docs, scratch notes,
anything an agent writes to be read later as background - no, and that is what
`read_write_per_project` is for. A spec is written to be read as context, so a
shared one is a channel from any project into every other.

All three lists mount at the host path they name, so a convention that says
"specs live in `~/specs`" keeps working inside the container without being
rewritten. That is the difference from `[core] share_dir`, which is
mounted at `~/shared` regardless of where it lives on the host because its job
is to be a well-known handoff point.

dejima creates the per-project directory; it never creates the one you named,
so a path that is not there is refused as the typo it is. Naming a
`read_write_per_project` root's `projects` directory in either of the other
two lists is refused as well - handing that over is handing over every
project's.

An entry is **refused, not warned about**, if it overlaps anything dejima
relies on being out of a session's reach: the approval store, either audit
store, the epitaph store, every project's share, `~/.local/bin`, dejima's own
checkout, the project mount (already read-write, so listing it again is a
mistake worth surfacing), and **everything the selected harness keeps on the
host** - its config directories, the files staged and seeded from them, and
the state directories its manifest declares. A writable mount over any of
those would let a session approve its own domains, delete the audit findings
naming it, read another project's transcripts, or plant code that runs
unsandboxed on the host next time you start an agent. Overlap is checked in
both directions after resolving symlinks, so `read_write = ~` is caught too.

The harness half of that list is derived from what the harness declares, not
written down in dejima, so it covers whichever one you selected - `~/.claude`
for Claude Code, `~/.agents` and `~/.cline` for Cline - and covers a harness
added later without anyone extending a list.

Sessions are told which directories these are, so "everything else is
disposable" stays true in the briefing rather than becoming a trap.

### One-off mounts for a single launch

`--extra-readonly PATH` and `--extra-read-write PATH` add a path for one run
without editing the config. `--ro` and `--rw` are the short forms. Both are
repeatable, one path per occurrence:

```sh
dejima --ro ~/other-project ~/myproject          # read while migrating code out
dejima --rw ~/scratch --ro ~/reference ~/myproject
```

They **append** to the config's lists rather than replacing them, and they
are the same lists, so everything above applies unchanged: the existence
check, the refusal when a path overlaps something dejima keeps out of a
session's reach, the refusal when one path appears in both lists, and the
briefing sentence naming what a session can write. A flag says *where*, not
*whether*, and there is no flag that waives a refusal.

Two differences from the config form, both because a command line is not a
file. A relative path is accepted and made absolute against the working
directory, which a config file has no equivalent of. And a path containing a
colon is refused outright: both lists are colon-separated, so such a path
cannot be represented in one at all and would otherwise split into two
mounts that each fail the existence check.

## Suspending a session

Ctrl-Z backgrounds all of dejima - the container, the credential proxy, the
conversation shipper - and `fg` brings back a working session, with the terminal
put back the way the harness had it.

That takes doing, because a container run holds the terminal in raw mode, where
Ctrl-Z is not a signal at all: it is a byte, delivered to whatever is running
inside. A harness that implements Ctrl-Z itself then stops itself, and nothing
in a container can continue it - there is no job-control shell in there. So
dejima takes that one character back for the host while a session runs
(`bin/dejima-tty-suspend`). Ctrl-C and Ctrl-\ are deliberately left alone and
still reach the session, which is how a harness expects to be interrupted.

Suspending is not pausing, and the difference is worth knowing before you reach
for it. What stops is the host side: `dejima` itself, the container run, the
credential proxy and the conversation shipper, which share one process group so
the kernel stops and continues them together. The container is not in that
group. It keeps running under the container runtime, with its mounts, its
firewall grants and its forge token, and keeps making requests while the
terminal looks stopped - see
[what dejima does not sandbox](security.md#what-dejima-does-not-sandbox).

Suspending is not detaching either: the job belongs to the terminal you started
it from. For a session you want to pick up from somewhere else, run dejima
inside tmux and use [`dejima-attach`](remote-access.md).

## Shared scratch space

`~/shared` is a read-write bind mount of one project's directory under
`[core] share_dir` (default `~/.local/share/dejima/shared`, created
automatically) - separate from the project mount, for passing files
(screenshots, temp scripts) in and out of a session without touching the actual
checkout. Persists across sessions since it's a real directory, not a container
volume.

**One directory per project, not one for the host.** A launch mounts
`<share_dir>/projects/<slug>` at `~/shared`, where the slug is the project's
absolute path with every non-alphanumeric character replaced by a dash - the
same key the audit and epitaph stores use. So a session sees its own project's
handoff files and no other project's, and nothing an agent has been told
changes, because inside the container the path is still `~/shared`.

`dejima-share` is the host side of that:

```sh
dejima-share path            # the host directory for this project, created if new
dejima-share path ~/code/x   # …for another project
dejima-share list            # every project's share, with size and last write
dejima-share adopt           # move files left loose in share_dir into this project's
```

**To hand a file *to* a session,** put it in `dejima-share path` before
launching. That is what makes the inbound direction work without a mount that
every project can read.

**From another machine,** `sshfs` puts a project's share in your own file
manager over the SSH access you already have. Read
[Mounting the box's files](remote-access.md#mounting-the-boxs-files) before
setting that up: every byte and every filename in there was written by a
sandboxed session, and a desktop that mounts the directory indexes,
thumbnails and previews what it finds without waiting to be asked. Nothing
dejima runs is in that path, so the sanitising it does for its own output does
not reach there.

Treat it as a handoff point, not as general-purpose storage. If your own
project instructions tell agents to write somewhere at a fixed host path -
design docs, scratch notes, anything meant to outlive the session but stay out
of the project checkout - mount that directory instead, with
`[mounts] read_write_per_project`. It arrives at its own absolute path, so a
convention that says "put specs in `~/specs`" keeps working inside the
container without being rewritten to point at `~/shared` - and, like `~/shared`
itself, what a session finds there is this project's and not every project's.

`~/shared`, the project mount, and anything in `[mounts] read_write` or
`[mounts] read_write_per_project` are the only writable host paths in the
container. Everything else a session writes goes away with it.

**Clear it out periodically.** The per-project split bounds which sessions can
read what you left, and bounds nothing about how long. A project's share
persists by design, so anything in it is readable by every future session
against that project: a credential dropped in there to get one job done, and
then forgotten, is a credential you have handed to every session against that
project since. Nothing prunes `share_dir` - `dejima-share list` prints each
project's size and the date of its last write, and deleting is yours.

**Files from before the split.** `share_dir` used to be mounted whole, so
anything at its top level was visible to every session. Those files are still
there and are now mounted into nothing; dejima says so at every launch while
that is true, rather than moving an operator's files on its own.
`dejima-share adopt <project>` moves them into one project's share after
showing what it will move and asking, and it never overwrites.

## Reading what a session left behind

When a session compacts, the summary it writes is the only durable account of
what a long session worked out - and it goes with the container. dejima keeps
a copy host-side, in `[epitaph] dir`, from `bin/dejima`'s exit trap. That
directory is never mounted into a container.

Three commands read it, all defaulting to the repository you are standing in:

```sh
dejima-epitaph list                  # what is kept, oldest first
dejima-epitaph search "dns proxy"    # which one was it
dejima-epitaph show 12               # open it in $VISUAL or $EDITOR
```

`show` takes a position from the listing that `list` and `search` print, or
an epitaph's filename, and defaults to the newest. It opens an editor when
there is a terminal to open one on and writes to stdout when there is not, so
`dejima-epitaph show | grep` behaves. `--all` widens `list` and `search` to
every project on the machine, which is also how to see everything the store
holds.

**`list` says whether each session is still resumable.** Where it is, the
transcript the summary came from is still on disk, and `claude --resume
<session>` gives you the session itself rather than a summary of it. The
epitaph is what remains after the harness ages that transcript out.

**Nothing here hands an epitaph back to a session, and that is deliberate.**
A session can write its own transcript, so it can author what its own epitaph
says. Delivering that to a later session automatically would plant text in
its premises as established background, which is the channel the
never-mounted store exists to close. Reading one and deciding what to do with
it is the operator's, which is why `show` opens an editor rather than
injecting anything: the header it opens on records that this preserves what
was written rather than vouching for it.

**Kept until you delete them.** There is no rotation. Epitaphs are an
archive, and a count-based cap would delete oldest-first - the entries most
likely to hold reasoning nobody remembers. They are small (tens of KB each,
against transcripts a hundred times that), so the store is a housekeeping
question rather than a disk one: `[epitaph] dir` is a plain directory of
plain markdown, and `rm` is the current answer.

Setting `[epitaph] enabled = off` stops new ones being kept. It does not hide
what is already there: `list`, `search` and `show` keep working, because
turning the feature off is the point at which wanting to review and clear the
store is most likely.

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

Every session is told where it is running: a disposable, firewalled container
it should stay within, and if something genuinely needs to break out - broader
network, host changes, GUI/hardware - it should stop and ask rather than work
around the firewall. Whether the session can be resumed unrestricted on the
host afterwards is the harness's own answer, and each harness's briefing
fragment gives it: Claude Code's names `claude --resume`, Cline's says plainly
that its sessions do not leave the sandbox.

*How* the briefing reaches a session is per harness too, because they do not
agree on a mechanism. Claude Code takes it as a system prompt through the flag
its manifest names; Cline takes no such flag and registers no hook, so
`entrypoint.sh` renders it into a file the harness reads, root-owned and
read-only. A harness doing neither gets it through a `SessionStart` hook. What
the briefing *says* is none of theirs - one script composes it for all three
routes. See [development.md](development.md).

When GitHub is a push destination this session - `--allow-github-push`, or
`forge = github` under a pushing workflow - the briefing also tells the
session not to push branches or open pull requests on any project other than
the one it was pointed at. Lifting the default gives an agent the ability
without the reason it is normally off (see
[docs/security.md](security.md#github-push-blocked-by-default-optional-opt-in)),
so the reason is supplied where it will be read.

`git-push-guard.sh` (`PreToolUse`/`Bash`, also `DEJIMA`-gated) blocks any `git
push` whose resolved remote is not one of the configured forge's hosts, and any
push straight to a branch the workflow protects. Neither list is named here:
both are resolved host-side from the selected forge and workflow, so this is
the same rule whichever forge is in use. Like the other hooks, this is a
fast-fail guard against an overeager agent, not a hard security boundary - a
session has full shell access and could in principle edit `.git/config` to
route around it.
GitHub push is blocked by default too (see
[GitHub push](security.md#github-push-blocked-by-default-optional-opt-in) in
docs/security.md) unless `--allow-github-push` is given. For a real guarantee
against pushes to main/master, use branch protection on the remote itself.

Both this hook and the PATH shadow beside it read the decision out of
`docker/guard-lib.sh`, which is the only copy of the rules. A push that the
library cannot read is refused rather than passed through: an unresolvable
remote, `--mirror`, and `--git-dir` or `--work-tree`, each of which names a
repository other than the one the remote would be resolved in.

`merge-guard.sh` (`PreToolUse`/`Bash`, `DEJIMA`-gated) applies the configured
forge's policy inside the sandbox: the blocked merge command, and a command
aimed at a repository the session was not launched against. It's the API-side
counterpart to the rule above: a merge puts a branch on `main` without ever
performing a push, so `git-push-guard.sh` never sees it. A hook is handed a
command rather than a conversation, so it can't tell an instructed merge from
an unprompted one - which is why it's scoped to the sandbox rather than
applied everywhere. On the
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
