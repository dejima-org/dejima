#!/usr/bin/env bash
# SessionStart hook: when running inside the claude-sandbox Docker container
# (see https://github.com/anthropics/claude-code/tree/main/.devcontainer for
# the reference this is based on, and this repo's own README for the actual
# setup), inject a reminder of the sandbox's constraints and how to escape
# it. No-op outside the container.

if [ -z "${CLAUDE_SANDBOX:-}" ]; then
    exit 0
fi

session_id=$(jq -r '.session_id // empty')
resume_id="${session_id:-<unknown-session-id>}"

# /etc/hostname in a docker container is the container's own ID, which
# docker exec accepts directly - baking it into the suggested command below
# means the agent states its real container instead of guessing (a wrong
# guess that matches *another* running sandbox makes claude-sandbox-allow
# "succeed" against the wrong container).
container_id=$(cat /etc/hostname 2>/dev/null)
container_id="${container_id:-<container-id>}"

context=$(cat <<EOF
You are running inside the claude-sandbox Docker container, not directly on
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
  registry, GitHub read-only, the configured Gitea host, plus anything set
  via ALLOWED_DOMAINS). Requests to anything else will simply fail to
  connect. If a task needs one more domain and nothing else, that's a quick
  fix, not a reason to stop: tell the user to run
  \`bin/claude-sandbox-allow <domain> --container $container_id\` (add
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

If a task genuinely needs something else the sandbox can't provide -
broader network access than a domain or two, host-level or system changes,
GUI/hardware access - stop and explain clearly to the user what you need
and why, instead of trying to work around the firewall or sandbox yourself.
They can continue this exact session outside the container by running on
the host:

  claude --resume $resume_id

(session history is shared via the bind-mounted ~/.claude, so it will pick
up right where this left off).
EOF
)

jq -n --arg context "$context" '{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": $context
  }
}'
