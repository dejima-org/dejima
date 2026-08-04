#!/usr/bin/env bash
# PreToolUse hook: inside dejima, block a merge command matching
# DEJIMA_MERGE_BLOCK - a literal command prefix (the forge's PR command
# followed by its merge subcommand) resolved host-side by bin/dejima from
# the configured forge and workflow
# (see dejima-provider-lib.sh), not hardcoded to any one forge. The sandbox
# workflow is feature branch -> open a PR/MR -> a human merges; what lands
# on the default branch is an operator decision, exactly as it already is
# for `git push` (see git-push-guard.sh, whose no-direct-push-to-a-blocked-
# branch rule this is the API-side counterpart to - a merge reaches the
# branch without a push, so that guard never sees it).
#
# Deliberately not conditional on intent. A hook is handed a command, not a
# conversation, so it cannot tell an instructed merge from an unprompted one;
# the only honest place to draw the line is the context, and the context that
# needs the line is this one - headless unattended runs under
# --dangerously-skip-permissions, where nobody is watching the turn happen.
# On the host the hook is a no-op and an operator can still ask for a merge.
#
# Like its sibling this is a fast-fail guard against an overeager agent, not
# a hard security boundary: a sandbox session has full shell access and the
# forge token in its environment, so it could call the merge endpoint with
# curl directly. It stops the mistake, not the attack.
#
# DEJIMA_MERGE_BLOCK fails OPEN: empty means no command is blocked, so the
# hook is inert rather than conditionally installed - a workflow with no
# merge-block policy (or a forge with nothing to block) genuinely has none.

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
