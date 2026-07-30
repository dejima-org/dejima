#!/usr/bin/env bash
# SessionStart hook: when running inside the dejima Docker container
# (see https://github.com/anthropics/claude-code/tree/main/.devcontainer for
# the reference this is based on, and this repo's own README for the actual
# setup), inject a reminder of the sandbox's constraints and how to escape
# it. No-op outside the container.

if [ -z "${DEJIMA:-}" ]; then
    exit 0
fi

# Read stdin once - it's consumed by the first reader, and this hook now
# needs both session_id and cwd out of the same payload.
payload=$(cat)
session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty')
resume_id="${session_id:-<unknown-session-id>}"
project_dir=$(printf '%s' "$payload" | jq -r '.cwd // empty')
project_dir="${project_dir:-$PWD}"

# /etc/hostname in a docker container is the container's own ID, which
# docker exec accepts directly - baking it into the suggested command below
# means the agent states its real container instead of guessing (a wrong
# guess that matches *another* running sandbox makes dejima-allow
# "succeed" against the wrong container).
container_id=$(cat /etc/hostname 2>/dev/null)
container_id="${container_id:-<container-id>}"

# What the project says it needs, checked against what this container
# actually has. .dejima/ is on the read-write workspace mount, so it
# grants nothing - it's a declaration the user approves by hand on the host
# (see bin/dejima-project). Reporting the gap here is what turns
# "this fails mysteriously" into "tell the user to run one command".
requirements=""
decl_dir="$project_dir/.dejima"

# Everything below reads attacker-controllable text on its way into an
# agent's context window, so all three costs it can impose are bounded:
#
#   MAX_DECLARED  entries considered - the same cap read_declared() applies
#                 host-side, so this reports on the same window
#                 `dejima-project approve` will act on.
#   MAX_ENTRY_LEN characters per entry.
#
# Within that window the report is a strict subset of what `approve` accepts,
# never a superset: it never names something approve would reject, but it can
# stay silent about something approve would take - a dotless domain (the
# regex below requires a label separator, deliberately, so a bare
# IGNORE-PREVIOUS-INSTRUCTIONS can't be echoed into the context) and a valid
# domain longer than MAX_ENTRY_LEN are both approvable host-side and both
# silently skipped here. Fail-closed in the direction that matters: the worst
# case is a missing line of advice, not an unapproved entry presented as fine.
#   MAX_LISTED    entries actually named in the report; the rest are only
#                 counted. Without it 200 entries of 200 chars would be 40 KB
#                 of attacker-chosen tokens per section, and a big enough
#                 $requirements used to push the jq call at the end past
#                 Linux's 128 KiB MAX_ARG_STRLEN and emit nothing at all -
#                 silently costing every later session in the project its
#                 entire briefing.
MAX_DECLARED=200
MAX_ENTRY_LEN=200
MAX_LISTED=20

# Yields at most MAX_DECLARED entries and stops reading there, so the size of
# the file itself costs nothing either. `cat file; echo` supplies the newline
# a final line may lack.
read_declared_capped() {
    local line count=0
    while IFS= read -r line; do
        line="${line%%#*}"; line="${line// /}"
        [ -n "$line" ] || continue
        count=$((count + 1))
        [ "$count" -le "$MAX_DECLARED" ] || break
        [ "${#line}" -le "$MAX_ENTRY_LEN" ] || continue
        printf '%s\n' "$line"
    done < <(cat "$1"; echo)
}

# One listing per ecosystem, cached, instead of one probe per declared entry:
# an `npm ls -g` or `pip show` fork costs about a second, so probing 200
# declared entries would run past Claude Code's hook timeout and drop this
# context just as thoroughly as an oversized argv would.
installed_names() {
    case "$1" in
        apt)   dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null | sed -n 's/ install ok installed$//p' ;;
        npm)   npm ls -g --depth=0 --parseable 2>/dev/null | sed -n 's#.*/node_modules/##p' ;;
        # PEP 503: pip treats runs of [-_.] and case as equivalent, so
        # compare normalized names rather than miss `pip:typing-extensions`
        # against an installed `typing_extensions`.
        pip)   pip list --format=freeze 2>/dev/null | sed -n 's/^\([^=@ ][^=@ ]*\).*/\1/p' | tr 'A-Z._' 'a-z--' ;;
        cargo) cargo install --list 2>/dev/null | sed -n 's/^\([^ ][^ ]*\) v[^ ]*:$/\1/p' ;;
    esac
}

if [ -f "$decl_dir/dependencies" ]; then
    missing_deps=""
    missing_deps_n=0
    declare -A installed_cache=()
    while IFS= read -r spec; do
        # Same shape as valid_dep_spec() in dejima-project-lib.sh -
        # a leading dash (e.g. "--allow-unauthenticated") must not validate
        # as a name, or this hook would echo into the agent's context an
        # entry the project's own approve/status commands treat as rejected.
        [[ "$spec" =~ ^(apt|npm|pip|cargo):[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || continue
        kind="${spec%%:*}"
        name="${spec#*:}"
        [ -n "${installed_cache[$kind]+set}" ] || installed_cache[$kind]="$(installed_names "$kind")"
        [ "$kind" != pip ] || name="$(printf '%s' "$name" | tr 'A-Z._' 'a-z--')"
        # -F -x: a package name can contain "." and "+", both of which would
        # otherwise be regex metacharacters matching the wrong entry.
        grep -qxF -- "$name" <<< "${installed_cache[$kind]}" && continue
        missing_deps_n=$((missing_deps_n + 1))
        [ "$missing_deps_n" -le "$MAX_LISTED" ] && missing_deps="$missing_deps $spec"
    done < <(read_declared_capped "$decl_dir/dependencies")
    if [ "$missing_deps_n" -gt "$MAX_LISTED" ]; then
        missing_deps="$missing_deps (+$((missing_deps_n - MAX_LISTED)) more)"
    fi
    if [ -n "$missing_deps" ]; then
        requirements="$requirements
- Declared dependencies missing from this image:$missing_deps
  These need an image rebuild, so they cannot be added to this session. Tell
  the user to run, outside the sandbox:
    dejima-project approve \"$project_dir\"
  then restart the sandbox. Do not try to install them yourself."
    fi
fi

if [ -f "$decl_dir/allowed-domains" ]; then
    missing_domains=""
    missing_domains_n=0
    while IFS= read -r dom; do
        # One dot minimum, unlike valid_domain()'s optional label group: a
        # bare word is not a domain this hook could ever be reporting on, and
        # accepting one puts arbitrary attacker text ("IGNORE-PREVIOUS-...")
        # verbatim into the agent's context under a heading that reads as the
        # project speaking.
        [[ "$dom" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,62}\.)+[a-zA-Z0-9-]{1,63}$ ]] || continue
        # Every valid domain has a dot, a BRE metachar that would match any
        # char - escape it so "a.b" can't false-positive against "aXb".
        grep -q "^server=/${dom//./\\.}/" /etc/dnsmasq-sandbox-servers.conf 2>/dev/null && continue
        missing_domains_n=$((missing_domains_n + 1))
        [ "$missing_domains_n" -le "$MAX_LISTED" ] && missing_domains="$missing_domains $dom"
    done < <(read_declared_capped "$decl_dir/allowed-domains")
    if [ "$missing_domains_n" -gt "$MAX_LISTED" ]; then
        missing_domains="$missing_domains (+$((missing_domains_n - MAX_LISTED)) more)"
    fi
    if [ -n "$missing_domains" ]; then
        requirements="$requirements
- Declared domains not allowed in this session:$missing_domains
  Tell the user to run, outside the sandbox:
    dejima-project approve \"$project_dir\"
  (or, for one domain right now:
    bin/dejima-allow <domain> --container $container_id)"
    fi
fi

if [ -n "$requirements" ]; then
    requirements="

This project declares requirements this session does not satisfy:$requirements"
fi

context=$(cat <<EOF
You are running inside the dejima Docker container, not directly on
the user's machine, with
--dangerously-skip-permissions active (no tool-use confirmations).

What this means:
- The workspace directory is bind-mounted read-write and is the real
  project. ~/shared is also a real, persistent host directory (not part of
  the project) - use it to hand the user a file (a screenshot, a temp
  script) without touching the project checkout, or to pick up something
  they left there for you. Everything else in the container besides
  ~/.claude is disposable: installed system packages, anything outside the
  mounted paths, and the container itself go away when this run ends.
- Outbound network is restricted to an allowlist (Anthropic's API, the npm
  registry, GitHub read-only, the configured Gitea host, plus anything
  approved via dejima-allow). Requests to anything else will simply
  fail to connect. If a task needs one more domain and nothing else, that's
  a quick fix, not a reason to stop: tell the user to run
  \`bin/dejima-allow <domain> --container $container_id\` (add
  \`--global\` to persist it past this session) from a terminal outside the
  sandbox, then continue. Quote that --container value exactly as written
  here - it is this container's real ID, not something to infer.
- Stay within the task you were given. Since there are no permission
  prompts here, be more conservative than usual about anything destructive,
  irreversible, or outside the project directory.

Git workflow - do this even though nothing stops you from doing otherwise:
- Do new work in a git worktree for the feature branch, not by switching
  branches in place in the mounted checkout - that's the user's actual
  working copy, and changing its branch out from under them is disruptive
  even if you switch it back.
- The worktree MUST live under the mounted project directory itself, e.g.
  \`git worktree add .worktrees/<branch> -b <branch>\` run from the project
  root - never \`../<branch>\` or any other path outside it, including
  anywhere under \$HOME. Only the exact directory bind-mounted into this
  container is backed by real storage on the host; everything else,
  including what looks like the project's own parent directory, is
  container-local and silently disappears when the session ends - a
  worktree created there is real work that just gets thrown away. Add
  \`.worktrees/\` to \`.git/info/exclude\` (not \`.gitignore\` - this is
  sandbox-local, not something to commit) so it doesn't clutter \`git
  status\` for the user's real checkout.
- Push that branch to the Gitea remote, then run \`gitea-pr create\` from
  the worktree. Never push to GitHub (read-only, and not reachable for
  push regardless), and never push directly to main/master, on any remote.
  A \`git-push-guard.sh\` hook enforces both as a backstop, but treat them
  as the actual workflow to follow, not just a filter to route around.
  Merging is the operator's call, not yours - a \`gitea-merge-guard.sh\`
  hook blocks it here. Report the PR URL and stop.
- Write PR and issue bodies to a file and pass \`--body-file FILE\`, rather
  than \`--body "..."\` or a heredoc. Both of those put the entire body into
  the Bash command string, where \`deny-dangerous-bash.sh\` reads it - and
  that hook matches its patterns anywhere in the string, with no way to tell
  an instruction from prose that merely mentions one. A body describing a
  crash, a restart, or a destructive command it is warning about will get
  the call blocked, which looks like a broken tool rather than what it is.
  Writing the file first keeps the prose out of the command entirely.
  \`gitea-issue\` (list/view/create/comment/close/reopen) takes the same
  flag, for recording a problem you found but aren't fixing.

If a task genuinely needs something else the sandbox can't provide -
broader network access than a domain or two, host-level or system changes,
GUI/hardware access - stop and explain clearly to the user what you need
and why, instead of trying to work around the firewall or sandbox yourself.
They can continue this exact session outside the container by running on
the host:

  claude --resume $resume_id

(session history is shared via the bind-mounted ~/.claude, so it will pick
up right where this left off).$requirements
EOF
)

# Fed on stdin rather than as --arg: a single argv element is capped at 128
# KiB (MAX_ARG_STRLEN), and a context that overruns it makes jq fail outright,
# emitting no context at all. The bounds above keep $requirements far below
# that, but this removes the failure mode rather than staying just inside it.
printf '%s' "$context" | jq -R -s '{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": .
  }
}'
