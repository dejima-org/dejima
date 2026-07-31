#!/usr/bin/env bash
# PreToolUse hook: inside dejima, block `gitea-pr merge`. The sandbox
# workflow is feature branch -> `gitea-pr create` -> a human merges; what
# lands on main is an operator decision, exactly as it already is for
# `git push` (see git-push-guard.sh, whose no-direct-to-main rule this is
# the API-side counterpart to - a merge reaches main without a push, so that
# guard never sees it).
#
# Deliberately not conditional on intent. A hook is handed a command, not a
# conversation, so it cannot tell an instructed merge from an unprompted one;
# the only honest place to draw the line is the context, and the context that
# needs the line is this one - headless unattended runs under
# --dangerously-skip-permissions, where nobody is watching the turn happen.
# On the host the hook is a no-op and an operator can still ask for a merge.
#
# Like its siblings this is a fast-fail guard against an overeager agent, not
# a hard security boundary: a sandbox session has full shell access and the
# Gitea token in its environment, so it could call the merge endpoint with
# curl directly. It stops the mistake, not the attack.

if [ -z "${DEJIMA:-}" ]; then
    exit 0
fi

command=$(jq -r '.tool_input.command // empty')

# The leading class includes '/' so a path-qualified call is caught too -
# /usr/local/bin/gitea-pr is how the image installs it, and is what an agent
# reaching past a shadowed PATH would type. Word-splitting rather than a full
# shell parse, the same pragmatic tradeoff the sibling hooks make.
if [[ "$command" =~ (^|[[:space:]&\|\;/])gitea-pr[[:space:]]+merge([[:space:]]|$) ]]; then
    echo "Blocked by gitea-merge-guard.sh: merging is a human decision in the sandbox - the workflow is 'gitea-pr create', then the operator merges. Report the PR URL and stop." >&2
    exit 2
fi

exit 0
