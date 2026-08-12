#!/usr/bin/env bash
# PreToolUse hook: inside dejima, block a merge command matching
# DEJIMA_MERGE_BLOCK - a literal command prefix resolved host-side by
# bin/dejima from the configured forge and workflow, never hardcoded to one
# forge. What lands on the default branch is an operator decision, as it
# already is for `git push`; this is the API-side counterpart to
# git-push-guard.sh, since a merge reaches the branch without a push.
#
# Not conditional on intent: a hook is handed a command, not a conversation,
# so it cannot tell an instructed merge from an unprompted one. The line is
# drawn by context instead, and the context that needs it is this one -
# unattended runs under --dangerously-skip-permissions. On the host it is a
# no-op.
#
# A fast-fail guard against an overeager agent, not a boundary: a session has
# shell access and the forge token, so it could call the merge endpoint with
# curl. It stops the mistake, not the attack.
#
# Fails OPEN - empty means nothing is blocked, so a workflow with no
# merge-block policy genuinely has none rather than the hook guessing.

if [ -z "${DEJIMA:-}" ]; then
    exit 0
fi

if [ -z "${DEJIMA_MERGE_BLOCK:-}" ]; then
    exit 0
fi

command=$(jq -r '.tool_input.command // empty')

# DEJIMA_MERGE_BLOCK is a literal command prefix from the forge manifest,
# not a regex - escape its regex metacharacters before matching so a value
# like ".*" matches only that literal text, never "everything".
escaped_block=$(printf '%s' "$DEJIMA_MERGE_BLOCK" | sed -E 's/[][(){}.*+?^$\\|]/\\&/g')

# The leading class includes '/' so a path-qualified call is caught too -
# the Dockerfile installs each forge's CLI under /usr/local/bin, and that's
# what an agent reaching past a shadowed PATH would type. Word-splitting
# rather than a full shell parse, the same pragmatic tradeoff the sibling
# hook makes.
if [[ "$command" =~ (^|[[:space:]&\|\;/])$escaped_block([[:space:]]|$) ]]; then
    echo "Blocked by merge-guard.sh: merging is a human decision in the sandbox - open a PR/MR, then the operator merges. Report its URL and stop." >&2
    exit 2
fi

exit 0
