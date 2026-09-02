#!/usr/bin/env bash
# SessionStart hook: when running inside the dejima Docker container
# (see https://github.com/anthropics/claude-code/tree/main/.devcontainer for
# the reference this is based on, and this repo's own README for the actual
# setup), hand Claude Code the session briefing.
#
# Everything that composes that briefing lives in dejima-briefing-render.sh,
# baked into the image and shared with every harness. What is left here is the
# part that is Claude Code's and only Claude Code's: a hook payload in, a
# hookSpecificOutput envelope out. No-op outside the container.

if [ -z "${DEJIMA:-}" ]; then
    exit 0
fi

# Read stdin once - it's consumed by the first reader, and this hook needs
# both session_id and cwd out of the same payload.
payload=$(cat)
session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty')
project_dir=$(printf '%s' "$payload" | jq -r '.cwd // empty')

# When the briefing reaches the harness as an argument instead, it is already
# in the system prompt - whole, and where a compaction cannot reach it. All
# that is left for this hook is the one fact the entrypoint could not know,
# because the harness had not started yet and the id did not exist.
#
# Deliberately not the whole briefing as well: a SessionStart payload past
# roughly nine kilobytes is persisted to a file and replaced with a preview,
# so duplicating it here would cost the session its context window and deliver
# a truncated copy of something it already has in full.
if [ "${DEJIMA_BRIEFING_VIA_ARGS:-0}" = "1" ]; then
    [ -n "$session_id" ] || exit 0
    printf '%s' "This session's id is $session_id. It is what the resume command in your system prompt takes." \
        | jq -R -s '{
      "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": .
      }
    }'
    exit 0
fi

# The image's copy first, because that is the one that exists in a real
# session: this file is baked in beside it and registered by absolute path
# into the sandbox's --settings overlay, so nothing about it depends on the
# operator's ~/.claude. The sibling is the fallback so the hook can be run
# against a checkout - which is what the test suite does - and readlink -f is
# what turns a linked path back into the repo one.
#
# Missing or unreadable degrades to no briefing rather than failing the hook:
# a SessionStart hook that exits non-zero drops the whole session's context,
# which is worse than one missing paragraph.
render=/usr/local/lib/dejima/dejima-briefing-render.sh
if [ ! -x "$render" ]; then
    self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)"
    render="${self%/*}/dejima-briefing-render.sh"
fi
[ -x "$render" ] || exit 0

# Fed on stdin rather than as --arg: a single argv element is capped at 128
# KiB (MAX_ARG_STRLEN), and a context that overruns it makes jq fail outright,
# emitting no context at all. The renderer's own bounds keep it far below
# that, but this removes the failure mode rather than staying just inside it.
"$render" "$session_id" "${project_dir:-$PWD}" | jq -R -s '{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": .
  }
}'
