#!/bin/bash
# Shadows a forge CLI on PATH so the one subcommand a workflow blocks is
# refused whatever ran it.
#
# The rule is the one hooks/merge-guard.sh applies - a merge is the operator's
# decision, so the sandbox opens a PR and stops - moved off the harness's hook
# protocol and onto the command. It works for a harness that cannot intercept
# a tool call, and it compares argv rather than regex-matching a command
# string, so quoting, spacing and pipelines stop mattering.
#
# Fast-fail, not a boundary, exactly as the hook was: what actually decides
# whether a merge is possible is the scope of the token the forge issued. This
# stops an eager agent doing it by accident.
#
#   DEJIMA_MERGE_BLOCK   the full command prefix to refuse, e.g. "gitea-pr
#                        merge". Its first word is the command this shadows;
#                        the rest is the subcommand sequence being refused.
#   DEJIMA_FORGE_REAL_DIR  where the real CLIs live, behind the shadow.
set -u

self="$(basename "$0")"
real="${DEJIMA_FORGE_REAL_DIR:-/usr/local/lib/dejima/forge}/$self"

if [ ! -x "$real" ]; then
    echo "dejima: no forge CLI at '$real' for '$self'." >&2
    exit 127
fi

# Outside a dejima container, or with nothing blocked, this is a pass-through.
if [ -z "${DEJIMA:-}" ] || [ -z "${DEJIMA_MERGE_BLOCK:-}" ]; then
    exec "$real" "$@"
fi

read -ra blocked <<< "$DEJIMA_MERGE_BLOCK"
# The first word names the command; only the rest is a subcommand sequence to
# compare against argv. A block naming a different command than the one being
# run is not this invocation's business.
[ "${#blocked[@]}" -ge 1 ] || exec "$real" "$@"
[ "${blocked[0]}" = "$self" ] || exec "$real" "$@"

want=("${blocked[@]:1}")
if [ "${#want[@]}" -eq 0 ]; then
    # The whole command is blocked, not one of its subcommands.
    echo "Blocked by dejima's forge guard: '$self' is not available in the sandbox." >&2
    exit 1
fi

# argv has to begin with the blocked sequence. Flags before the subcommand are
# skipped so `gitea-pr --verbose merge 7` is still a merge.
args=("$@")
j=0
for w in "${want[@]}"; do
    while [ "$j" -lt "${#args[@]}" ] && [ "${args[$j]#-}" != "${args[$j]}" ]; do
        j=$((j + 1))
    done
    [ "$j" -lt "${#args[@]}" ] || exec "$real" "$@"
    [ "${args[$j]}" = "$w" ] || exec "$real" "$@"
    j=$((j + 1))
done

echo "Blocked by dejima's forge guard: merging is a human decision in the sandbox - open a PR/MR, then the operator merges. Report its URL and stop." >&2
exit 1
