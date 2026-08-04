# Provider axes: forges, workflows, harnesses

[← dejima README](../README.md)

dejima's forge (Gitea/Forgejo/...), workflow (worktree-and-PR, or something
else) and harness (Claude Code, or another agent CLI) behaviour are not
hardcoded into core. Each is a directory under `forges/`, `workflows/` or
`harnesses/`, selected by `[core] forge`, `[core] workflow` and
`[core] harness` in `~/.config/dejima/config`. Shipped today:

| Axis | Directory | Selector | Ships |
| --- | --- | --- | --- |
| forge | `forges/` | `[core] forge` | `forges/gitea`, `forges/github`, `forges/none` |
| workflow | `workflows/` | `[core] workflow` | `workflows/worktree-pr`, `workflows/branch-push`, `workflows/local-only` |
| harness | `harnesses/` | `[core] harness` | `harnesses/claude-code` |

See [Shipped providers](#shipped-providers) below for what each one is for.

**A provider is data.** Nothing in dejima sources, `eval`s or executes a
manifest or a briefing fragment - a manifest is parsed with exactly the
discipline the config file itself gets (unknown key is fatal, every value is
type-checked, a line count cap), and a briefing fragment is prose that gets
substituted into and handed to the agent, never interpreted as code. The one
thing a provider ships that *does* run is a forge's `bin/` - copied into the
Docker image at build time (`docker/Dockerfile`: `COPY forges/`, then every
file under a `*/bin/` is installed) as an ordinary program the agent invokes
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
`forge.conf`, `workflow.conf`, `harness.conf`. Format is the same
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
| `export` | `NAME=key` or `NAME=@key` for the `env_export` forge key - see [Forge](#forge) below. |
| `template` | Prose that may contain `{{placeholder}}` markers; the placeholder names are checked against the briefing whitelist at composition time, not here. |
| `keyspec` | One element of a `keys` list - see [The `keys` field](#the-keys-field-a-providers-own-config-schema) below. |
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
| `merge_block` | `?command` | (empty) | The literal command prefix `hooks/merge-guard.sh` refuses inside the sandbox (e.g. `gitea-pr merge`) - only when the workflow's `block_merge = on`. |
| `keys` | `?list:keyspec` | (empty) | This forge's own `[forge.<name>]` config schema - see above. |
| `requires` | `?list:identifier` | (empty) | Which of this forge's own config keys an operator is expected to set for it to actually work - checked at launch by two refusal rules (partly-configured, and none-configured-with-a-fixed-host) when the workflow pushes; see [Validation](#validation). A key with a non-empty schema default never counts as missing for either check. |
| `host_keys` | `?list:identifier` | (empty) | Config keys (from `keys`) that hold a literal hostname - unioned by `forge_hosts` into the firewall allowlist and the push guard's allowed hosts. |
| `url_keys` | `?list:identifier` | (empty) | Config keys that hold a URL - `forge_hosts` strips scheme and path and unions the bare host in the same way as `host_keys`. |
| `fixed_hosts` | `?list:hostname` | (empty) | Hostnames this forge always needs reachable, independent of any config value (`github` uses this - `github.com`, `ssh.github.com`, `api.github.com` are the same three hosts for every operator, so there's nothing to configure and nothing to get wrong). |
| `hosts_allowlisted_by_core` | `bool` | `off` | `on` means this forge's hosts are ones core already allowlists in its own right - GitHub's published ranges, which every session can read from over 443 whatever forge is selected. Core then keeps them out of `DEJIMA_FORGE_HOSTS` (the extra-domains path, which resolves a name into the port-unrestricted `allowed-domains` ipset and exempts it from DNS-rebind protection - right for an internal self-hosted host, a silent widening for a public one) and, when the workflow pushes, opens core's own GitHub push grant to them instead: port 22 to those same ranges, logged and verified by the firewall's startup self-check. They still reach `DEJIMA_PUSH_HOSTS`, so `git-push-guard.sh` permits the push. |
| `install` | `?list:relpath` | (empty) | Files under this forge's own directory that ship into the image - the only manifest key naming something that actually gets copied and executed. |
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
install       = <its two CLIs, listed relative to its own bin/ directory>
env_export    = GITEA_API=api GITEA_SSH_HOST=ssh_host GITEA_TOKEN=@token_file
```

Reading it: gitea offers the `pr` and `issues` capabilities; its briefing
prose refers to `gitea-pr`/`gitea-issue`; `hooks/merge-guard.sh` blocks
`gitea-pr merge` when the workflow asks for that; `[forge.gitea]` gets three
config keys (`ssh_host`, `api`, `token_file`) from `keys`; an operator is
expected to set all three (`requires`); `ssh_host` is a literal hostname and
`api` is a URL, both of which end up in the firewall allowlist and the push
guard's host list; `install` names the two executables under its own `bin/`
subdirectory (`gitea-pr` and `gitea-issue`), which is what the Dockerfile
copies into the image; and the container gets `GITEA_API`, `GITEA_SSH_HOST`,
and `GITEA_TOKEN` (the *contents* of the file at `token_file`, not its path)
as environment variables.

## Workflow

`workflows/<name>/workflow.conf`. Every key:

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `requires` | `?list:identifier` | (empty) | Forge capabilities this workflow needs (checked against the selected forge's `capabilities` at launch). |
| `push` | `bool` | `on` | Whether this workflow pushes at all. When `off`, `DEJIMA_PUSH_HOSTS` is empty regardless of the forge, so `git-push-guard.sh` refuses every push. |
| `blocked_branches` | `?list:identifier` | (empty) | Branch names `git-push-guard.sh` refuses a direct push to, even on an allowed host. |
| `block_merge` | `bool` | `off` | When `on`, resolves the selected forge's `merge_block` command into `DEJIMA_MERGE_BLOCK` for `hooks/merge-guard.sh`. |
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
| `command` | `identifier` | `claude` | The container's main process for this harness. |
| `keys` | `?list:keyspec` | (empty) | This harness's own `[harness.<name>]` config schema - same grammar as a forge's `keys`. |
| `resume_command` | `?template` | (empty) | Prose template (may use `{{session_id}}`) shown at the end of the briefing for resuming this exact session on the host. |
| `briefing` | `?relpath` | (empty) | This harness's briefing fragment file, relative to its own directory. |

Worked example, `harnesses/claude-code/harness.conf`:

```
command        = claude
keys           = projects_dir:path=~/.claude/projects statusline_path:path=~/.claude/statusline.sh
resume_command = claude --resume {{session_id}}
briefing       = briefing.md
```

Reading it: the container's main process is `claude`; `[harness.claude-code]`
gets `projects_dir` and `statusline_path`, both `path`-typed with defaults;
resuming the session on the host is `claude --resume <session id>`, with
`{{session_id}}` filled in at composition time; and its briefing fragment is
`briefing.md`.

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
3. The core closing text (how to hand a task back to the operator when the
   sandbox genuinely can't do it).
4. The selected harness's fragment (today, just the resume command).

Every `{{placeholder}}` in the assembled text must be on a fixed whitelist
(`pr_command`, `issue_command`, `forge_name`, `forge_ssh_host`,
`blocked_branches`, `container_id`, `project_dir`, `workspace_dir`,
`session_id`, `resume_command`, `writable_mounts`) - an unrecognized one is a
hard refusal, not a literal pass-through. `{{session_id}}` and
`{{container_id}}` are deliberately left as `@@SESSION_ID@@`/
`@@CONTAINER_ID@@` markers instead of being resolved here, since neither is
known until the container is actually running; `hooks/sandbox-context.sh`
fills those two in at `SessionStart`.

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
- Whatever the forge's own `env_export` names (e.g. `GITEA_API`,
  `GITEA_SSH_HOST`, `GITEA_TOKEN`).

`hooks/git-push-guard.sh` reads `DEJIMA_PUSH_HOSTS` and
`DEJIMA_BLOCKED_BRANCHES`; `hooks/merge-guard.sh` (renamed from
`gitea-merge-guard.sh` in this phase) reads `DEJIMA_MERGE_BLOCK` as a
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
- A forge whose `requires` keys are **partly** set - some configured, some
  not (a key written but left empty, as `install.sh`'s commented-out starter
  config makes easy, counts as not set: it resolves to nothing, and every
  call the forge makes with it would fail inside the container) - is refused
  as a likely typo, but only when the workflow actually
  pushes: a non-pushing workflow never invokes the forge, so e.g. gitea's
  `ssh_host` alone (set only so the firewall allows fetches) is a legitimate
  configuration, not a typo. A wholly unconfigured forge is never flagged by
  this rule - that's the case above.
- A pushing workflow whose forge has **none** of its required settings
  configured is refused too, even when `fixed_hosts` means the "resolves to
  no host" rule above never fires. This is what catches `github`: its single
  `requires` key (`push_token_file`) means "partly configured" (the rule
  above) can never trigger for it either - there's nothing to be partial
  between - so without this rule a pushing workflow could select `github`
  with no `push_token_file` set and launch anyway, `fixed_hosts` masking the
  fact that nothing was actually configured.

Two qualifications worth stating explicitly for the "partly configured" rule:
it only applies when the workflow's `push = on` (a non-pushing workflow never
touches the forge, so an incomplete `[forge.<name>]` section is harmless),
and a required key with a non-empty schema default - gitea's `token_file`,
defaulting to `~/.config/gitea/token` - never counts as missing, since its
resolved value is already correct even when the operator never wrote it.

## Shipped providers

| axis | provider | notes |
| --- | --- | --- |
| forge | `gitea` | PRs and issues via `gitea-pr`/`gitea-issue`, shipped into the image |
| forge | `github` | PRs and issues via `gh`; needs its own write-capable `push_token_file`; opens `ssh.github.com:22` |
| forge | `none` | no capabilities; pair with `local-only` |
| workflow | `worktree-pr` | worktree → push → PR, stops at the PR |
| workflow | `branch-push` | worktree → push, stops at the branch |
| workflow | `local-only` | commits locally, pushes nothing |
| harness | `claude-code` | the only harness today |

**Selecting `forge = github` is a real posture change, not just a config
choice.** It opens `ssh.github.com:22` for push - the read-only GitHub access
every session gets regardless (clone, fetch, `gh` API calls over port 443)
never needs port 22 at all. It opens it through core's existing GitHub push
grant (`ALLOW_GITHUB_PUSH`, the same one `--allow-github-push` uses), which
its `hosts_allowlisted_by_core = on` is what asks for: port 22 to GitHub's
published ranges and nothing else, logged like every other allowed
connection and verified by the firewall's own startup self-check. Only when
the selected workflow actually pushes - `forge = github` with
`workflow = local-only` leaves port 22 shut. And `[forge.github] push_token_file` is
deliberately a *separate*, write-capable token from `[github] token_file`
(a read-only fine-grained PAT used for read access independent of which
forge is selected): promoting the read-only token to push duty would defeat
the point of scoping it read-only in the first place. Because `gh` only ever
reads one token variable, dejima warns at startup when both files are
present and non-empty - the write-capable `push_token_file` wins for that
launch, and the read-only `token_file` is not used while `forge = github`.
