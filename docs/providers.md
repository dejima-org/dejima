# Provider axes: forges, workflows, harnesses

[← dejima README](../README.md)

dejima's forge (Gitea/Forgejo/...), workflow (worktree-and-PR, or something
else), harness (Claude Code, or another agent CLI) and model backend
(Anthropic, OpenRouter, something you serve) behaviour are not hardcoded into
core. Each is a directory under `forges/`, `workflows/`, `harnesses/` or
`backends/`. Shipped today:

| Axis | Directory | Selector | Ships |
| --- | --- | --- | --- |
| forge | `forges/` | `[core] forge` | `forges/gitea`, `forges/github`, `forges/none` |
| workflow | `workflows/` | `[core] workflow` | `workflows/worktree-pr`, `workflows/branch-push`, `workflows/local-only` |
| harness | `harnesses/` | `[core] harness` | `harnesses/claude-code`, `harnesses/cline` |
| backend | `backends/` | `[harness.<name>] backend` | `backends/anthropic`, `backends/anthropic-api-key`, `backends/openrouter`, `backends/self-hosted` |

The backend is selected per harness rather than in `[core]`, because it is the
harness that talks to a model API - see [Model backends](#model-backends).

See [Shipped providers](#shipped-providers) below for what each one is for.

**A provider is data.** Nothing in dejima sources, `eval`s or executes a
manifest or a briefing fragment - a manifest is parsed with exactly the
discipline the config file itself gets (unknown key is fatal, every value is
type-checked, a line count cap), and a briefing fragment is prose that gets
substituted into and handed to the agent, never interpreted as code. The one
thing a provider ships that *does* run is a forge's `bin/` - copied into the
Docker image at build time (`docker/Dockerfile`: `COPY forges/`, then
`docker/install-forge-bins.sh` installs exactly what the manifests declare)
as an ordinary program the agent invokes
on `PATH`, the same as `git` or `curl`. That program never feeds back into a
decision dejima itself makes; it's just a CLI the image happens to carry.

This matters because a provider directory is ordinary repo content, and the
repo itself can be the mounted workspace (dejima sandboxing its own
checkout). Parsing rather than sourcing a manifest is what keeps "a session
edited a manifest" from meaning "a session ran code on the host at the next
launch."

**The point of the whole arrangement: adding a provider never means editing
core.** A forge or harness declares its own `[forge.<name>]`/
`[harness.<name>]` config schema *in its own manifest* (the `keys` field,
below) - core holds no forge-specific or harness-specific schema at all.
Adding a forge is adding a directory whose manifest describes it; nothing
elsewhere needs to change.

## The manifest file

Each provider directory has exactly one manifest file, named for its axis:
`forge.conf`, `workflow.conf`, `harness.conf`, `backend.conf`. Format is the same
`key = value` shape as the main config file:

- One `key = value` pair per line; surrounding whitespace is trimmed.
- Blank lines and lines starting with `#` or `;` are comments.
- Any other line without an `=` is a malformed-line error.
- A key not in that axis's schema (below) is an **unknown key** error, not a
  silent pass-through.
- A value that fails its key's type check is a **hard** error, not a warning.
- Capped at 200 lines; a longer file is refused outright.

A missing key is not an error - it resolves to that key's schema default
(empty string for a key with none), the same way an absent key in the main
config file does.

## Types

Every key's type is one of the main config file's own types (`bool`,
`enum:a|b|...`, `path`, `hostname`, `url`, `identifier`, `int:min:max`), plus
a handful that only a manifest uses, because they land somewhere a config
value never does:

| Type | Meaning |
| --- | --- |
| `command` | Space-separated words (a bare name or a multi-word one like `gh pr`) - lands in prose an agent runs, so nothing shell-active is legal. |
| `relpath` | A path relative to the provider's own directory, no leading `/` and no `..` - a manifest may only name a file it ships. |
| `homepath` | A path under the sandbox user's home: no leading `/`, no `..`, and unlike `relpath` a leading dot is allowed, since the directories a harness keeps state in are dotfiles. |
| `envpair` | `NAME=VALUE`, where NAME is upper-case and VALUE carries no whitespace and nothing shell-active - it becomes an `ENV` line in a generated Dockerfile. |
| `depspec` | A dependency spec: `apt:`/`npm:`/`pip:`/`cargo:` plus a package name, or `tarball:<name>@<sha256>:<url>`. Validated by `valid_dep_spec`, the same function an operator's approved dependency goes through, because it ends up in the same place - a Dockerfile `RUN` line built on the host. |
| `export` | `NAME=key` or `NAME=@key` for the `env_export` forge key - see [Forge](#forge) below. |
| `template` | Prose that may contain `{{placeholder}}` markers; the placeholder names are checked against the briefing whitelist at composition time, not here. |
| `keyspec` | One element of a `keys` list - see [The `keys` field](#the-keys-field-a-providers-own-config-schema) below. |
| `repopath` | `<subcommand>:<first path segment>` for the `repo_paths` forge key - where a repository appears in a path rather than behind a flag. |
| `list:TYPE` | Space-separated (not colon-separated, unlike a config-file list) elements, each checked against `TYPE`. |

A leading `?` on any type (`?hostname`, `?list:identifier`, ...) makes the
key optional: empty/absent is legal. Without it, a non-empty value is
required whenever the key itself has no schema default.

## The `keys` field: a provider's own config schema

A forge or harness manifest can declare `keys = ...`: a space-separated list
of `name:type` or `name:type=default` elements, each parsed by the same
`keyspec` grammar the config file's own three-column schema table uses
(name, type, default) - just packed into one manifest line instead of a
row hardcoded in core. This is what a `[forge.<name>]`/`[harness.<name>]`
config section's own keys, types and defaults come from - **core never
hardcodes them.**

Worked example, gitea's `keys` line:

```
keys = ssh_host:?hostname api:?url token_file:path=~/.config/gitea/token
```

Three elements:

- `ssh_host:?hostname` - optional (`?`), type `hostname`, no default (so
  unset resolves to empty).
- `api:?url` - optional, type `url`, no default.
- `token_file:path=~/.config/gitea/token` - **not** optional (no `?`), type
  `path`, default `~/.config/gitea/token`. A non-optional element must carry
  a default - the same invariant every hardcoded core schema row already
  holds: "always has a value" only means something if there is one.

Once gitea is the selected forge, `[forge.gitea] ssh_host`,
`[forge.gitea] api` and `[forge.gitea] token_file` become real config keys an
operator can set, resolved the same way as any other config key
(`config_get`, `--print-config`), purely from this one manifest line.

## Forge

`forges/<name>/forge.conf`. Every key:

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `capabilities` | `?list:identifier` | (empty) | What this forge can do - `pr`, `issues`, etc. A workflow's own `requires` is checked against this set at launch; a workflow asking for a capability this forge lacks is refused. |
| `pr_command` | `?command` | (empty) | The PR-management command name the forge's briefing prose and `env_export`/`merge_block` refer to. |
| `issue_command` | `?command` | (empty) | The issue-management command name, same idea. |
| `merge_block` | `?command` | (empty) | The command prefix refused inside the sandbox - only when the workflow's `block_merge = on`. Enforced by `docker/forge-guard.sh`, which shadows the named CLI on PATH and compares argv, so it holds for a harness that cannot intercept a tool call; `hooks/merge-guard.sh` applies the same rule to a reported command for the harnesses that can, through the same library, so the two cannot disagree. Matched as a run of consecutive non-flag arguments, so a flag before the subcommand does not slip past it. |
| `repo_flags` | `?list:flag` | (empty) | The option names this forge's CLI accepts for naming a repository other than the one the session was launched against - `--repo -R` for `gh`. `docker/forge-guard.sh` refuses a value that is not that repository, in every spelling of the flag itself: `--repo x`, `--repo=x`, `-R x`, `-Rx`, and the letter inside a short-flag cluster (`-wR x`, `-wRx`). Fast-fail, not a boundary, for the same reason `merge_block` is not one: the session holds the token. Leave it empty for a CLI that resolves the repo itself and refuses another host, as the gitea ones do - a forge is not required to be aimable. **Enforced only for a CLI that also appears in `merge_block` or `disclose`:** those two are what name the commands the shadow is linked over and the hook checks against, so a forge declaring this and neither of them would get the rule applied to nothing. |
| `identity_keys` | `?list:identifier` | (empty) | Which of this forge's own `keys` name an **account** rather than the forge itself - the credential paths, which differ per session, where an API URL does not. One declaration, two rules: a key named here is one an `[identity.<name>]` section may set, and one a project may not declare in its own `.dejima/`. Core keeps no list of its own, so a forge whose credential is spelled differently needs no change here. The identity inherits the type from this forge's `keys` entry, not a second copy of it. |
| `repo_env` | `?identifier` | (empty) | The environment variable this forge's CLI reads for the same thing - `GH_REPO`. Declared separately because it takes no argument and would otherwise be the way around every flag above. |
| `repo_paths` | `?list:repopath` | (empty) | A repository this forge's CLI names in a path rather than in a flag, as `<subcommand>:<first segment>` - `api:repos` for `gh api repos/<owner>/<name>/...`. Scoped to a subcommand on purpose: comparing every positional argument that contains two slashes would refuse an issue title that happens to look like one, and a false refusal costs an honest agent a working command. Paths carrying `gh`'s own `{owner}`/`{repo}` placeholders are left alone, since those resolve to this repository by construction. |
| `disclose` | `?disclosures` | (empty) | Which of this forge's commands send a body the session authored, as comma-separated `kind:command prefix` entries - `pr:gh pr create, issue:gh issue create, ...`. `docker/forge-guard.sh` prepends a marker to the body of a matching command, so a PR, issue or comment an agent wrote says so. The three kinds are `pr`, `issue` and `comment`; the wording of each marker is core's, not the manifest's, so that dejima says one thing about agent authorship whichever forge is selected. Unlike `merge_block` this does not depend on the workflow: what a workflow permits is a policy, who wrote the text is a fact. |
| `keys` | `?list:keyspec` | (empty) | This forge's own `[forge.<name>]` config schema - see above. |
| `requires` | `?list:identifier` | (empty) | Which of this forge's own config keys an operator is expected to set for it to actually work - checked at launch by two refusal rules (partly-configured, and none-configured-with-a-fixed-host) when the workflow pushes; see [Validation](#validation). A key with a non-empty schema default never counts as missing for either check. |
| `host_keys` | `?list:identifier` | (empty) | Config keys (from `keys`) that hold a literal hostname - unioned by `forge_hosts` into the firewall allowlist and the push guard's allowed hosts. |
| `url_keys` | `?list:identifier` | (empty) | Config keys that hold a URL - `forge_hosts` strips scheme and path and unions the bare host in the same way as `host_keys`. |
| `fixed_hosts` | `?list:hostname` | (empty) | Hostnames this forge always needs reachable, independent of any config value (`github` uses this - `github.com`, `ssh.github.com`, `api.github.com` are the same three hosts for every operator, so there's nothing to configure and nothing to get wrong). |
| `hosts_allowlisted_by_core` | `bool` | `off` | `on` means this forge's hosts are ones core already allowlists in its own right - GitHub's published ranges, which every session can read from over 443 whatever forge is selected. Core then keeps them out of `DEJIMA_FORGE_HOSTS` (the open-class path, which permits a name on every port and exempts it from the check that refuses an answer pointing inside a private network - right for an internal self-hosted host, a silent widening for a public one) and, when the workflow pushes, opens core's own GitHub push grant to them instead: port 22 to those same ranges, logged like every other allowed connection. The startup self-check asserts the refusal when the opt-in is off, and skips that check when it is on, so a break in the opt-in plumbing shows up as a failed push rather than a container that will not start. They still reach `DEJIMA_PUSH_HOSTS`, so `git-push-guard.sh` permits the push. Name-free in core, but GitHub-specific in effect: this key means "core already allowlists these hosts in its own right", which today is only true of GitHub's ranges, so a future forge whose hosts are not among those must leave it `off` - setting it `on` for anything else grants no firewall allowance at all plus an irrelevant GitHub push grant. |
| `install` | `?list:installspec` | (empty) | The CLIs this forge puts on PATH in the image - the only manifest key naming something that actually gets copied and executed. Either a path under the forge's own directory, or `system:<name>` for a command the image already provides from a package. The list is the gate, not a description of one: `docker/install-forge-bins.sh` installs exactly what is declared, and fails the build when a declared file is missing, when a declared `system:` command is not in the image, and when a forge ships a file under its `bin/` that it does not declare. Every command a forge names anywhere - `pr_command`, `issue_command`, `merge_block`, `disclose` - has to appear here, because a CLI that is not behind the shadow is one the guards cannot reach: the entrypoint refuses to start rather than leave a block or a disclosure looking enforced. |
| `env_export` | `?list:export` | (empty) | `NAME=key` (the config key's resolved value) or `NAME=@key` (the *contents* of the file the config key names) pairs - the environment variables `bin/dejima` passes into the container for this forge. The `@` form is how a token reaches the container without its path being mistaken for the secret. |

Worked example, `forges/gitea/forge.conf`:

```
capabilities  = pr issues
pr_command    = gitea-pr
issue_command = gitea-issue
merge_block   = gitea-pr merge
keys          = ssh_host:?hostname api:?url token_file:path=~/.config/gitea/token
requires      = ssh_host api token_file
host_keys     = ssh_host
url_keys      = api
install       = <its CLIs, listed relative to its own bin/ directory>
env_export    = GITEA_API=api GITEA_SSH_HOST=ssh_host GITEA_TOKEN=@token_file
```

Reading it: gitea offers the `pr` and `issues` capabilities; its briefing
prose refers to `gitea-pr`/`gitea-issue`; `hooks/merge-guard.sh` blocks
`gitea-pr merge` when the workflow asks for that; `[forge.gitea]` gets three
config keys (`ssh_host`, `api`, `token_file`) from `keys`; an operator is
expected to set all three (`requires`); `ssh_host` is a literal hostname and
`api` is a URL, both of which end up in the firewall allowlist and the push
guard's host list; `install` names the executables under its own `bin/`
subdirectory (`gitea-pr`, `gitea-issue` and `gitea-actions`), and those three
are exactly what the image build installs; and the container gets `GITEA_API`, `GITEA_SSH_HOST`,
and `GITEA_TOKEN` (the *contents* of the file at `token_file`, not its path)
as environment variables.

## Workflow

`workflows/<name>/workflow.conf`. Every key:

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `requires` | `?list:identifier` | (empty) | Forge capabilities this workflow needs (checked against the selected forge's `capabilities` at launch). |
| `push` | `bool` | `on` | Whether this workflow pushes at all. When `off`, `DEJIMA_PUSH_HOSTS` is empty regardless of the forge, so `git-push-guard.sh` refuses every push. |
| `blocked_branches` | `?list:identifier` | (empty) | Branch names `git-push-guard.sh` refuses a direct push to, even on an allowed host. |
| `block_merge` | `bool` | `on` | When `on`, resolves the selected forge's `merge_block` command into `DEJIMA_MERGE_BLOCK` for `hooks/merge-guard.sh`. Defaults on so a workflow that omits it refuses a merge rather than permitting one; every shipped workflow sets it anyway. |
| `requires_worktree` | `bool` | `off` | When `on`, this workflow's briefing fragment must contain a `<!-- core: worktree -->` marker, which the core worktree-containment paragraph is spliced into - see below. |
| `autonomy` | `enum:commit\|push-branch\|open-pr` | `commit` | Gates `<!-- requires: autonomy=VALUE -->` spans in this workflow's own briefing fragment (see below); also read by the forge/harness resolvers where autonomy-conditioned prose applies. |
| `briefing` | `?relpath` | (empty) | This workflow's briefing fragment file, relative to its own directory. |

Worked example, `workflows/worktree-pr/workflow.conf`:

```
requires          = pr
push              = on
blocked_branches  = main master
block_merge       = on
requires_worktree = on
autonomy          = open-pr
briefing          = briefing.md
```

Reading it: needs a forge with the `pr` capability; pushes are allowed;
direct pushes to `main` or `master` are blocked; merging is blocked in the
sandbox (using whichever `merge_block` command the selected forge names);
its briefing fragment must (and does) carry the worktree marker; its
autonomy is `open-pr` (push the branch and open the PR without stopping to
ask, per its briefing prose); and its prose lives in `briefing.md` next to
the manifest.

### Briefing fragment markers

A workflow's `briefing.md` is plain Markdown plus two marker forms that
`briefing_compose` resolves before the agent ever sees the text:

- `<!-- core: worktree -->` - replaced with the core worktree-containment
  paragraph (only when `requires_worktree = on`; present but unused
  otherwise). This text is core's, not the provider's, because getting it
  wrong silently discards real work - a workflow can only opt in or out via
  `requires_worktree`, never edit or omit the paragraph itself.
- `<!-- requires: CONDITION --> ... <!-- end -->` - the enclosed prose
  survives only when `CONDITION` holds; both marker lines are always
  dropped. `CONDITION` is either a bare forge capability (checked against
  the selected forge's `capabilities`, e.g. `<!-- requires: issues -->`) or
  `autonomy=VALUE` (checked against this workflow's own `autonomy`).

## Harness

`harnesses/<name>/harness.conf`. Every key:

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `install` | `?depspec` | (empty) | What installs this harness into the image, as a dependency spec (`npm:`, `apt:`, `pip:`, `cargo:` or `tarball:`) - the same grammar and the same validator an operator's approved dependency goes through. The base image carries no harness: the selected one installs into a layer of its own on top of it, keyed on its name, so switching `[core] harness` switches images rather than accumulating every harness into the one every project shares. Empty means "already present", which is only true of something the base image installs for another reason. |
| `image_dirs` | `?list:homepath` | (empty) | Directories this harness needs inside the sandbox user's home, created 0700 and owned by them in its own image layer. They exist because only enumerated paths *inside* them are mounted from the host, and Docker creates a mount's missing parent root-owned - which would leave the session unable to write the state it keeps beside them. Relative to `$HOME`; a leading `/` or a `..` is refused, since both reach a `mkdir -p` running as root at build time. |
| `image_files` | `?list:homepath` | (empty) | Files this harness needs to exist in the sandbox user's home, created empty at 0600 in its own image layer. For a harness that reads a credential from a fixed path: an absent file and an empty one are not reliably the same to it. Created in the image rather than at container start, so whatever the credential transport mounts at that path simply shadows it. |
| `image_env` | `?list:envpair` | (empty) | `NAME=VALUE` pairs set in this harness's image layer, for anything it wants in the environment of every session of its own. Deliberately narrow - no whitespace, nothing shell-active - because each becomes an `ENV` line in a generated Dockerfile. |
| `command` | `identifier` | `claude` | The container's main process for this harness, and the name the wrapper shadows on `PATH`. `[core] command` defaults to it. |
| `command_path` | `?path` | (empty) | Where the real binary lives, behind the shadow. |
| `api_domains` | `?list:hostname` | (empty) | Hostnames this harness's own machinery must reach - its update host, its telemetry endpoint. They join the built-in part of the permitted set rather than the operator's, and are not exempted from the check that refuses an answer pointing inside a private network - a harness's endpoints are public names, and exempting a public name is what turns one influenced answer into egress to an internal host. |
| `api_styles` | `?list:identifier` | (empty) | Which backend `api_style`s this harness has a client for. `claude-code` speaks `anthropic`; `cline` speaks both, which is what makes it the backend-agnostic one. Empty means unchecked. |
| `guards` | `?list:identifier` | (empty) | Which of dejima's guard rails this harness can host: `bash-deny`, `push-guard`, `merge-guard`, `notify`. A name outside that set is refused rather than treated as an unknown guard, since a typo would otherwise turn a guard off silently. The ones a harness does not declare are named at launch - see "What a harness must be able to do" in [development.md](development.md). |
| `assumed_backend` | `?provider:backend` | (empty) | Which backend this harness talked to before `[harness.<name>] backend` existed. Read only when that key is unset, and it writes into the operator's config rather than being consulted at launch - the one key here that does. |
| `briefing_args` | `?args` | (empty) | The flag that carries the briefing to a harness taking it on the command line - for Claude Code, `--append-system-prompt`. `dejima-harness-wrapper` reads the rendered briefing and passes it as a single value, so every invocation carries it and not only the entrypoint's. Set, the session-start hook stops carrying the briefing and reduces to the session id, which is the one thing that does not exist until the harness starts. |
| `briefing_path` | `?homepath` | (empty) | Where this harness reads its briefing from, relative to `$HOME`, for a harness that has no session-start hook to be handed it through. Set, `entrypoint.sh` renders the briefing into that path root-owned and read-only before the session starts, and refuses to start it at all if that fails. Empty for a harness that takes the briefing on the command line (`briefing_args`, which is how Claude Code gets it) or that can be handed it through a session-start hook. |
| `no_confirm_args` | `?args` | (empty) | The flags that make the harness run without confirming each tool call. Required in practice: dejima refuses to launch a harness that names none, because unattended operation is the premise the container is built on (R1 in [development.md](development.md)). |
| `settings_args` | `?args` | (empty) | How this harness is told to read dejima's own settings layer, mounted at `/etc/dejima-settings.json`. Empty for a harness that takes its overrides some other way. |
| `keys` | `?list:keyspec` | (empty) | This harness's own `[harness.<name>]` config schema - same grammar as a forge's `keys`. |
| `resume_command` | `?template` | (empty) | Prose template (may use `{{session_id}}`) shown at the end of the briefing for resuming this exact session on the host. Substitution is not recursive and the `template` type has no `=`, so a resume command that needs a second placeholder or an environment variable goes in the harness's briefing fragment instead, where both resolve. |
| `transcript_update` | `enum:append\|rewrite` | `append` | How this harness's transcript files change, which decides how they can be read incrementally. `append` means the file only grows, one record per line, so the conversation shipper reads forward from a byte offset and consumes only whole lines. `rewrite` means the file is replaced wholesale, where an offset would land in the middle of a document - it is re-read when it changes and the records already shipped are skipped by count. Declared rather than sniffed, because append semantics against a rewritten file ship garbage. |
| `briefing` | `?relpath` | (empty) | This harness's briefing fragment file, relative to its own directory. |

Worked example, `harnesses/claude-code/harness.conf`:

```
command         = claude
command_path    = /opt/node-tools/bin/claude
guards          = bash-deny push-guard merge-guard notify
no_confirm_args = --dangerously-skip-permissions
settings_args   = --settings /etc/dejima-settings.json
keys            = projects_dir:path=~/.claude/projects file_history_dir:path=~/.claude/file-history statusline_path:path=~/.claude/statusline.sh
resume_command  = claude --resume {{session_id}}
briefing        = briefing.md
```

Reading it: the container's main process is `claude`, wrapped on `PATH` in
front of the real binary at `command_path` so that every invocation - not
only the one the entrypoint makes - gets `--dangerously-skip-permissions`
and dejima's settings layer; `[harness.claude-code]`
gets `projects_dir`, `file_history_dir` and `statusline_path`, all `path`-typed
with defaults;
resuming the session on the host is `claude --resume <session id>`, with
`{{session_id}}` filled in at composition time; and its briefing fragment is
`briefing.md`.

## Model backends

`backends/<name>/backend.conf`. Which model API a session talks to, and how the
credential proxy presents the credential to it.

**"Backend" and not "provider",** which is what the industry usually calls a
model API. This document already calls forge, workflow and harness "provider
axes", and one word for both reads as one thing. A harness keeps its own
vocabulary: `cline` writes a `providers.json` with a `lastUsedProvider` key,
and `bin/harness/cline.sh` translates.

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `upstream` | `?url` | (empty) | Where the proxy forwards to. Required unless `credential` is `none`, which runs no proxy. |
| `api_style` | `enum:anthropic\|openai` | (required) | Which dialect the endpoint speaks. A property of the API rather than of any harness: Anthropic's Messages API and an OpenAI-compatible one are different wire formats. A harness declares which it can speak in `api_styles`, and a launch pairing the two wrongly is refused rather than sending well-formed requests in a shape the endpoint cannot parse. |
| `proxied_domain` | `?hostname` | (empty) | The name the in-container TLS terminator answers for, and what `/etc/hosts` pins to loopback. Required unless `credential` is `none`. On this axis rather than the harness's: a harness reaches whichever endpoint it is configured for, so the name belongs to the endpoint. Declared on the harness, the terminator would answer for one API while the session talked to another, and the credential the proxy exists to withhold would be the one in use. |
| `credential` | `enum:static\|anthropic-oauth\|none` | (required) | Whether there is a credential, and whether it expires. `static` is read and sent; `anthropic-oauth` is refreshed against `oauth_endpoint` and the rotated token written back to the host file, which is what keeps a host-side login working rather than being signed out by a sandbox run; `none` is a model you serve, with nothing to withhold and so no proxy at all. |
| `auth_header` | `identifier` | `Authorization` | Which header carries it. |
| `auth_format` | `authformat` | `Bearer {token}` | How it is written. Must contain `{token}`, so a backend wanting a bare key or a prefix of its own needs no code; a format without it produces a proxy that starts, answers, and sends every request unauthenticated. |
| `strip_headers` | `?list:identifier` | (empty) | Headers that must not travel beside the injected one. `x-api-key` next to an `Authorization` is two answers to the same question, and which one an API prefers is not dejima's to guess. The auth header is never stripped from under itself. |
| `ensure_headers` | `?list:headerpair` | (empty) | `NAME=VALUE` that has to appear in a comma-list header, merged into whatever the client sent and left alone when already present. Anthropic's OAuth beta is the one shipped example. |
| `oauth_endpoint` | `?url` | (empty) | Required by the `anthropic-oauth` kind, meaningless to `static`. |
| `oauth_client_id` | `?identifier` | (empty) | Same. |
| `keys` | `?list:keyspec` | (empty) | This backend's own `[backend.<name>]` config schema, exactly as a forge's works. A backend with a credential is expected to declare `credential_file`. |
| `requires` | `?list:identifier` | (empty) | Which of those must be set for a launch to proceed. |

### What pairs with what

Compatibility is not a list anyone maintains: it is the backend's `api_style`
against the harness's `api_styles`, checked at launch. This table is what those
declarations currently work out to.

It answers whether dejima will pair the two, which is a question about
dialects. Whether the endpoint then serves the request is the endpoint's to
answer, and for a Claude subscription credential the answer depends on the
harness - see [A subscription credential is Claude
Code's](#a-subscription-credential-is-claude-codes-and-anthropic-enforces-that)
below.

| Backend | `claude-code` | `cline` | Credential | You configure |
| --- | --- | --- | --- | --- |
| `anthropic` | yes | yes | OAuth, refreshed and written back | nothing, once you have logged in on the host |
| `anthropic-api-key` | yes | yes | a static key, held on the host | nothing, if Claude Code signed you in; otherwise `[backend.anthropic-api-key] credential_file` |
| `openrouter` | no | yes | a static key, held on the host | `[backend.openrouter] credential_file` |
| `self-hosted` | no | yes | none, and so no proxy at all | `[backend.self-hosted] base_url` |

`claude-code` speaks Anthropic's Messages API and nothing else, so the two
OpenAI-compatible backends are refused with it - at launch, naming both sides,
rather than by sending well-formed requests in a shape the endpoint cannot
parse. `cline` has a client for each dialect, which is what makes it the
backend-agnostic one.

Adding a backend does not change this table by hand: a new directory whose
`api_style` is one a harness already declares works with that harness the day
it lands.

### A subscription credential is Claude Code's, and Anthropic enforces that

`backends/anthropic` reads the OAuth credential Claude Code writes when you
sign in with a Claude subscription. **Anthropic serves that credential to
Claude Code and refuses other clients, per model.** Observed on a Max
subscription: `claude-haiku-4-5` is served, `claude-opus-5` and
`claude-sonnet-5` are refused, while an otherwise identical request from
Claude Code succeeds.

The refusal arrives as **HTTP 429 `rate_limit_error`**, with a body whose
message is the word `Error`. It is indistinguishable from a quota problem
from the inside, which is worth knowing before you spend an afternoon on
your usage graphs: the account can be nowhere near any limit and every
request will still be refused.

So with `[core] harness = cline` and `backend = anthropic`, expect Haiku to
work and the larger models not to. For those, point cline at a backend whose
credential is yours to spend rather than a subscription's:

```
[harness.cline]
backend = anthropic-api-key    # console billing, key held on the host
# or
backend = openrouter
```

`claude-code` with `backend = anthropic` is unaffected - that pairing is the
one Anthropic is serving.

**dejima does not work around this**, and that is a limit on what dejima does
rather than an opinion about the attempt.

The credential proxy substitutes the credential and changes nothing else: the
header block the API receives is the harness's own, down to not adding an
`Accept-Encoding` the client did not send. Getting past this gate would mean
sending a system prompt the harness never wrote, so that the request presents
as a different product - which is the one thing the proxy is built not to do,
and would put a second answer to "which client is this" inside the component
whose whole job is to pass the first one through unchanged.

It would also be brittle in a way that costs the operator rather than dejima:
it works until the shape it copies changes, and the failure lands on their
account.

Which models are gated is Anthropic's to change, and the table above is an
observation on one subscription rather than a documented policy - if it moves,
this section moves with it.

**Which backend a launch uses is the harness's setting**, `[harness.<name>]
backend`, overridable for one launch with `--backend`. Per harness because
that is how it is used: one harness against Anthropic and another against
something else, on the same machine.

No harness ships a default for it, for the reason `[core] harness` has none. A
harness may instead declare `assumed_backend`: what it was talking to before
the key existed, which dejima writes into the operator's config the first time
it finds the key unset, and says so. That is a migration rather than a default
- recorded once in the operator's own file, so a later change to dejima cannot
move a session whose config never changed. A harness only states it where the
value is not a guess; one whose past endpoint depended on other settings
declares nothing, and an unset backend is then a refusal.

**Nothing here is a secret.** A backend declares *where* its credential is
read from - `credential_file` is a path - never what it is. The file it names
is read host-side per request and is never mounted into the container, which
is the property the whole arrangement exists for.

## Tool

Not an axis: a launch selects one forge, one workflow and one harness, and
enables zero or more tools. Everything else about it is the same - a manifest
that is data, validated by the same schema machinery, never sourced.

The keys are deliberately few. A tool declares what it is, what installs it,
what its environment needs and what the session should be told about it. There
is no key for a hook, a mount, a domain or a guard, because a tool that needed
one of those would be a change to the boundary rather than a program on PATH.

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `description` | `text` | *(required)* | One line, shown when the layer builds and in the session briefing. |
| `install` | `depspec` | *(required)* | The same grammar a dependency uses. In practice a `tarball:` spec, because a tool has to be pinned by digest - see [docs/tools.md](tools.md) for why that is a rule rather than a preference. |
| `install_layout` | `enum:prefix\|binary` | `prefix` | The archive's shape. `prefix` is one enclosing directory, stripped so `bin/` lands in the same place whatever the release called its top level. `binary` is an archive that IS the executable: stripping a component there would strip the binary and extract nothing, silently. |
| `image_env` | `?list:envpair` | (empty) | `NAME=VALUE` pairs the layer sets. **Every name must be namespaced to the tool** - `RTK_*` for `rtk` - and a launch refuses one that is not. This becomes a Dockerfile `ENV`, which every process in the container inherits, so a bare `NO_COLOR` or `DO_NOT_TRACK` changes the harness and everything else too. A harness manifest may use bare names there because a harness is the container's main process; a tool is one program among many. |
| `command` | `identifier` | *(required)* | What it puts on PATH. |
| `instructions` | `?relpath` | (empty) | A markdown fragment appended to the session briefing under a core-owned heading, so a tool describes itself once and every harness gets the same words. This is the whole of the per-harness wiring: dejima renders it rather than letting the tool's installer patch a harness config. |

## Session briefing composition

The text a `SessionStart` hook injects into the agent is assembled
**host-side**, by `briefing_compose` in `bin/dejima-provider-lib.sh`, never
inside the container - giving `hooks/sandbox-context.sh` the provider
directories to compose from would mean mounting them into the sandbox, the
opposite of "providers are data, never sourced." In reading order:

1. The core preamble (what the sandbox is, why the firewall is load-bearing
   for the agent too) - fixed prose, not overridable by any provider.
2. The selected workflow's fragment, with its worktree/capability/autonomy
   markers resolved.
3. The commit-granularity rule, when the project ships a `.dejima/corpus`
   file - see [configuration.md](configuration.md#declaring-that-the-history-is-evidence).
   Conditional core prose, gated the same way the GitHub-push paragraph is,
   and absent for every project that has not declared it.
4. The core closing text (how to hand a task back to the operator when the
   sandbox genuinely can't do it).
5. The selected harness's fragment: how to resume this session on the host,
   and where the history it would resume from lives. Both are the harness's
   own facts rather than core's - Claude Code resumes from a bind-mounted
   `~/.claude`, Cline from a per-project state directory the command has to
   name - so the closing sentence is in the fragment and not in the preamble.

Every `{{placeholder}}` in the assembled text must be on a fixed whitelist
(`pr_command`, `issue_command`, `forge_name`, `forge_ssh_host`,
`blocked_branches`, `container_id`, `project_dir`, `workspace_dir`,
`session_id`, `resume_command`, `writable_mounts`, `network_allowlist`,
`no_confirm_args`, `harness_state_dir`) - an unrecognized one is a
hard refusal, not a literal pass-through. `{{session_id}}` and
`{{container_id}}` are deliberately left as `@@SESSION_ID@@`/
`@@CONTAINER_ID@@` markers instead of being resolved here, since neither is
known until the container is actually running.

### How the briefing reaches the session

**A session-start hook is a size-limited channel, which is why it is not the
only route.** Claude Code persists a large `SessionStart` payload to a file
and injects a short preview in its place: measured in a dejima container, 9KB
arrived whole and 21KB did not. A composed briefing plus a project's own
`.dejima.md` runs well past that, so most of the briefing silently never
reached the session - the briefing failing in the quietest way available to it.
A system prompt has no such limit, and unlike anything in the conversation it
cannot be compacted away later either.

So a harness may name a flag in `briefing_args`, and
`dejima-harness-wrapper` passes the briefing with it on every invocation.
`entrypoint.sh` renders the briefing before the session starts, which is what
resolves `@@CONTAINER_ID@@` and appends the dependency report and `.dejima.md`;
`hooks/dejima-briefing-render.sh` is that renderer, and `sandbox-context.sh`
calls the same one.

The hook still runs for a harness using `briefing_args`, carrying only
`@@SESSION_ID@@`'s value - the harness has not started when the entrypoint
runs, so the id does not exist yet. A harness declaring no `briefing_args` gets
the whole briefing through the hook as before.

Substitution is one pass over the assembled text, not a fixed point: a value
that itself contains a `{{placeholder}}` leaves it unresolved and the whole
composition is refused. That is why a harness whose resume command needs more
than `{{session_id}}` puts the command in its fragment rather than in
`resume_command`.

A third route exists for a harness that neither registers a hook nor takes a
flag: `briefing_path` names a file it reads, which `entrypoint.sh` writes from
the same rendering, root-owned and read-only.

The result is mounted **read-only** into the container - so a session can
never rewrite what the *next* session is told, even a session running
against dejima's own checkout. `dejima --print-briefing` composes and prints
it without launching anything, for inspecting exactly what a session would
see.

## What bin/dejima passes into the container

Only resolved values, never an unresolved manifest or a provider directory
itself:

- `DEJIMA_FORGE_HOSTS` - every hostname the selected forge needs *added to
  the firewall's allowlist* (`host_keys`, the host part of `url_keys`, plus
  `fixed_hosts`), unioned by `forge_hosts`. Empty for a forge declaring
  `hosts_allowlisted_by_core` - core already allows those, and adding them
  here would widen them to every port and drop their DNS-rebind protection.
- `DEJIMA_PUSH_HOSTS` - every hostname `forge_hosts` resolves (including a
  `hosts_allowlisted_by_core` forge's, which the entry above omits) when the
  workflow's `push = on`, otherwise empty.
- `DEJIMA_BLOCKED_BRANCHES` - the workflow's `blocked_branches`.
- `DEJIMA_MERGE_BLOCK` - the forge's `merge_block`, but only when the
  workflow's `block_merge = on`; otherwise empty.
- `DEJIMA_FORGE_REPO_FLAGS` and `DEJIMA_FORGE_REPO_ENV` - the forge's
  `repo_flags` and `repo_env`, with `DEJIMA_FORGE_REPO` holding the
  `<owner>/<name>` of the workspace's `origin` remote. Empty when the forge
  declares neither, and also when the workspace has no origin to read - in
  which case a command naming any repository is refused, since there is
  nothing it could legitimately be naming.
- Whatever the forge's own `env_export` names (e.g. `GITEA_API`,
  `GITEA_SSH_HOST`, `GITEA_TOKEN`).

`hooks/git-push-guard.sh` reads `DEJIMA_PUSH_HOSTS` and
`DEJIMA_BLOCKED_BRANCHES`; `hooks/merge-guard.sh` reads `DEJIMA_MERGE_BLOCK` as a
regex-escaped literal command prefix. Two different failure directions,
both deliberate:

- `DEJIMA_PUSH_HOSTS` fails **closed** - empty means no host is allowed, so
  every push is refused. A no-forge or non-pushing workflow becomes
  *enforced*, not merely described.
- `DEJIMA_BLOCKED_BRANCHES` fails **open** - empty means no branch is
  protected, which is correct for a workflow with genuinely no branch
  policy.
- `DEJIMA_MERGE_BLOCK` fails **open** the same way - empty makes
  `merge-guard.sh` inert rather than conditionally installed.

## Validation

`provider_validate_selection` checks the selected forge/workflow/harness at
every launch:

- Each manifest must validate.
- A workflow's `requires` must be a subset of the forge's `capabilities` - a
  workflow asking for a capability the forge doesn't have is refused
  outright.
- The workflow's `autonomy` must be something the forge can actually back up:
  `autonomy = open-pr` needs a forge offering the `pr` capability; `autonomy
  = push-branch` needs `push = on` (it can't stop at a push it never makes).
  A mismatch is refused at launch rather than discovered by the agent
  mid-task.
- A pushing workflow (`push = on`) needs a forge that resolves to somewhere
  to push to. A wholly unconfigured forge with nothing to configure at all
  (`forge = none`) is refused, pointing at a forge that needs no host
  configured (`forge = github`) or a workflow that does not push; a forge
  that has config keys but none of them resolve to a host is refused with
  "configure it, or select `forge = github`, or `forge = none` with a
  workflow that does not push".
- A forge whose `requires` keys are **partly** set is refused as a likely
  typo, but only when the workflow pushes. A key written but left empty
  counts as not set - it resolves to nothing, and every call made with it
  would fail inside the container. A non-pushing workflow never invokes the
  forge, so gitea's `ssh_host` alone (set only so the firewall allows
  fetches) is legitimate. A required key with a non-empty schema default -
  gitea's `token_file` - never counts as missing, since its resolved value is
  correct even unwritten. A wholly unconfigured forge is the case above, not
  this one.
- A pushing workflow whose forge has **none** of its required settings is
  refused too, even where `fixed_hosts` stops the "resolves to no host" rule
  firing. This catches `github`: with a single `requires` key there is
  nothing to be partial between, so without this rule a pushing workflow
  could select it with no `push_token_file` and launch anyway, `fixed_hosts`
  masking that nothing was configured.

## Shipped providers

| axis | provider | notes |
| --- | --- | --- |
| forge | `gitea` | PRs and issues via `gitea-pr`/`gitea-issue`, shipped into the image |
| forge | `github` | PRs and issues via `gh`; needs its own write-capable `push_token_file`; opens `ssh.github.com:22` when the selected workflow pushes |
| forge | `none` | **default** - no capabilities, no host; pair with `local-only` |
| workflow | `worktree-pr` | worktree → push → PR, stops at the PR |
| workflow | `branch-push` | worktree → push, stops at the branch |
| workflow | `local-only` | **default** - commits locally, pushes nothing |
| harness | `claude-code` | hosts every guard; **not a default** - `[core] harness` must be set |
| harness | `cline` | backend-agnostic, so it can be pointed at an open-weight model served locally; hosts no guards, and needs `[harness.cline] model` set and a CPU with AVX2 |
| backend | `anthropic` | Anthropic on a subscription login; the OAuth token is refreshed and written back to the host |
| backend | `anthropic-api-key` | Anthropic on API billing, whether the key came from Claude Code's console login (`primaryApiKey` in `~/.claude.json`, the default) or a file you hold yourself |
| backend | `openrouter` | a hosted OpenAI-compatible API; a static key, held on the host |
| backend | `self-hosted` | a model you serve; no credential and so no proxy, and the endpoint must be host-local |

### Harness integration maturity

Both harnesses are supported, and supported means the same thing for each: a
manifest, a plugin, tests, and the capability bar in
[development.md](development.md) either met or declared unmet. It does not mean
they have had the same amount of use, and the gap is wide enough to say so
rather than let the word "supported" imply otherwise.

**Claude Code is the harness dejima was built around.** Nearly every mechanism
here - the credential proxy, the briefing, the per-project state mounts, the
exit audit - was designed against it and generalised afterwards. It hosts all
four guards. Its rough edges were found by running it for real work, over and
over, which is a kind of coverage no test suite substitutes for.

**Cline is new, and has barely been used.** Its integration was built
deliberately and is tested, but a test only covers what someone thought to
check. The first run against a live model immediately turned up a bug no test
had: Cline silently discards a `providers.json` entry with no `updatedAt` and falls back
to its own hosted endpoint, which presents as a connection failure to a host
nobody configured. The first real session turned up a second, in a component
Cline does not own at all - the conversation shipper passed its payload as a
command-line argument, which Cline's larger tool results overflow. It hosts no
guards, so every launch names what is not in force.

Neither of those was a bad integration. That is the normal rate of discovery
for something this new, and it is the reason to expect more.

So: if you are choosing between them with no other reason to prefer one, choose
`claude-code`. Choose `cline` for what it offers that the other does not - it
can be pointed at any endpoint, including a model you serve yourself - and
expect to be the person who finds the next crack.


### Model backend maturity

The same caveat the harnesses and forges get, and for the same reason: four
backends in one table invites the reading that each got the same amount of
use, and they did not.

**`anthropic` is the one dejima was built around.** The credential proxy, the
in-container terminator, the refresh-and-write-back - all of it was designed
against a subscription login and generalised afterwards. It has been used for
real work continuously, which is the coverage no test substitutes for.

**`anthropic-api-key` works and has not been leaned on.** It was verified end
to end on a real machine: the model answers, billing shows as API usage, the
key stays on the host and the container holds only a placeholder. That is one
confirmed launch rather than months of use, and the difference matters for the
same reason it does above.

**`openrouter` is at the same level.** Built from the same manifest shape,
exercised against a fake upstream and through a full launch, and confirmed
against the real endpoint. What has not happened yet is a long tail of
sessions through it, so expect the rough edges that only volume finds.

**`self-hosted` runs no proxy at all**, which makes it the simplest of the
four and the one with least to go wrong in dejima: there is no credential to
withhold, so the session reaches the endpoint directly and dejima's only job
is refusing an address that is not host-local. It has been run against a local
model. What it does not get is any of the credential machinery's protection,
because there is nothing to protect.

If you are choosing with no other reason to prefer one, and you have a
subscription, `anthropic` is the path with the most miles on it. The other
three are supported in the same sense the second harness is: built
deliberately, tested, and newer than the thing they sit beside.


### Forge integration maturity

The same caveat the harnesses get, for the same reason: two forges listed in
one table invites the reading that each got the same consideration, and they
did not.

**gitea is the forge dejima is developed on.** Every PR in this repo was
opened through it, every issue filed through it, and its three CLIs are
dejima's own - which is why they do things `gh` does not, like showing only
the review threads still outstanding. Its rough edges were found by using it.

**GitHub has never been run end to end.** It was built from the manifest
outward and tested at the config layer, and what that missed is instructive:
`forge = github` could not start a container at all under `worktree-pr`, the
only workflow that opens PRs, because the merge shadow had no `gh` to shadow.
Ten tests exercised the forge and none of them reached the entrypoint. Fixing
that immediately turned up a second thing, that `gh --repo owner/name pr merge
N` walked straight past the merge block. Neither was a hard bug to find once
anyone looked.

Two differences from the gitea path remain, both now closed in code and worth
knowing about because they are what a second forge costs:

- **Review feedback needs its own tool.** `gh pr view --comments` prints
  reviews and comments with no resolution state anywhere in the output,
  because the REST API it uses does not carry any - `isResolved` exists only
  on `reviewThreads` in GraphQL. So this forge ships `github-pr comments`,
  which does that one query and otherwise matches `gitea-pr comments`:
  unresolved threads by default, `--all` to include the resolved ones marked
  as such, and a count of what was hidden. Everything else `gitea-pr` does has
  a `gh` subcommand already.
- **`gh` can be aimed past the sandboxed repository, and is stopped.** The
  gitea CLIs resolve the repository from `origin` and refuse an origin that is
  not on the configured host, so there is no flag or variable to compare and
  nothing for this guard to declare. That is a narrower confinement than it
  sounds: `origin` lives in `.git/config`, inside the read-write project mount,
  and the gitea token is account-wide - so a session that rewrites `origin` to
  another repository **on the same host** reaches it. What bounds that is the
  token's scope, as it is for `gh`. `gh` takes `--repo`
  on nearly every subcommand, reads `GH_REPO`, and names repositories in `gh
  api` paths, so this forge declares all three (`repo_flags`, `repo_env`,
  `repo_paths`) and `docker/forge-guard.sh` refuses a value that is not the
  launched-against repository. Fast-fail, not a boundary, exactly as
  `merge_block` is: the session holds the token and could call the API
  directly. What actually bounds it is the token's scope, so a per-repository
  fine-grained PAT is the expected shape of `push_token_file`.

  **What it sees, and what it does not.** Worth stating both, because a guard
  described only by what it catches reads like a boundary. It compares, case
  -insensitively: `--repo x` and `--repo=x`; `-R x` and `-Rx`; the same letter
  inside a short-flag cluster, `-wR x` and `-wRx`; `GH_REPO`; and
  `gh api repos/<owner>/<name>/...`, with or without a leading slash. A launch
  that resolved no repository at all refuses every one of those rather than
  waving them through.

  It does not see a GraphQL `mutation` sent through `gh api graphql`, a
  repository named in an `--jq` expression or a `-F`/`-f` field, an API path
  under a segment other than `repos/`, or `gh` invoked through something else
  that passes the repository along. Nor can it know that the workspace's
  `origin` is the repository you meant: it compares against whatever origin
  the checkout has, so a workspace pointing somewhere unexpected shifts what
  counts as "this repository" rather than being caught by this. That list is
  not exhaustive either, and it is not meant to be - widening it further would
  mean parsing each subcommand's flags, which is the coupling this guard
  exists to avoid. The token's scope is what bounds the ones it misses.

So: if you have a choice, `gitea` is the better-worn path. Choose `github`
because that is where your repositories are, which is a good reason - and
expect to be the person who finds the next crack.

**The shipped defaults are deliberately the non-pushing pair**
(`forge = none`, `workflow = local-only`). A fresh install has no forge host
and no forge credential, so any default naming a real forge would be an
assertion about the operator's setup that nothing has established - and,
because a pushing workflow whose forge resolves to no host is refused (see
[Validation](#validation)), such a default would make an unconfigured
`dejima` refuse to launch at all. The defaults instead say the one thing
that is true of every fresh install: this sandbox pushes nowhere yet.
Pushing is opted into by naming both a pushing workflow and a forge that
resolves.

**A PR, issue or comment a session writes says an agent wrote it.** The body
is prepended with a marker - "Summary generated by LLM agent" on a PR,
"Filed by LLM agent" on an issue, "Comment by LLM agent" on a comment -
before it reaches the forge. This happens in `docker/forge-guard.sh`, which
shadows the forge's CLI on PATH, rather than in the CLIs themselves: dejima
wrote two of the three and a marker living in the tools would mean the
answer to "does dejima disclose this" depended on which forge an operator
picked. It applies on edits as well as creates, because the marker describes
where the text came from rather than the event that wrote it.

Two things it does not cover. A command that sends no body has none added -
`gh pr create --fill` takes its body from commit messages, and inventing one
would be worse than leaving it. And running a forge CLI on the host, outside
a sandbox, marks nothing: there the person running it wrote the body.

**Once, whatever the body already says.** A body that already opens with the
marker gets no second one - the marker is a statement rather than a count, and
a body saying an agent wrote it has disclosed what this exists to disclose.
That matters because agents write it themselves: every issue on a project
worked on this way opens with that line, so one reading the existing issues
concludes it is the house style. The same words further down the body are
prose about disclosure rather than the disclosure, and still get one
prepended. The session is also told the marker is added for it, which is the
half that stops it being written at all.

**Selecting `forge = github` is a real posture change, not just a config
choice.** It opens `ssh.github.com:22` for push - the read-only GitHub access
every session gets regardless (clone, fetch, `gh` API calls over port 443)
never needs port 22 at all. It opens it through core's existing GitHub push
grant (`ALLOW_GITHUB_PUSH`, the same one `--allow-github-push` uses), which
its `hosts_allowlisted_by_core = on` is what asks for: port 22 to GitHub's
published ranges and nothing else, logged like every other allowed
connection. The startup self-check asserts that port 22 is refused when the
opt-in is off, and skips that check when it is on, so a break in the opt-in
plumbing shows up as a failed push rather than a container that will not
start. The
port restriction is an IPv4 statement; what makes port 22 shut *at all*
without this grant is that the container blocks IPv6 as well, so an
allowlist naming one address family is not the whole of it. Only when
the selected workflow actually pushes - `forge = github` with
`workflow = local-only` leaves port 22 shut. And `[forge.github] push_token_file` is
deliberately a *separate*, write-capable token from `[github] token_file`
(a read-only fine-grained PAT used for read access independent of which
forge is selected): promoting the read-only token to push duty would defeat
the point of scoping it read-only in the first place. Because `gh` only ever
reads one token variable, dejima warns at startup when both files are
present and non-empty - the write-capable `push_token_file` wins for that
launch, and the read-only `token_file` is not used while `forge = github`.
