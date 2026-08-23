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

# The blocked sequence has to appear as a run of consecutive non-flag
# arguments. Flags are dropped first, so `gitea-pr --verbose merge 7` is still
# a merge.
#
# Anywhere in that run rather than at the start of it, because a flag's value
# is indistinguishable from a subcommand here: in `gh --repo o/r pr merge 7`
# the first non-flag argument is `o/r`, and requiring the match to begin there
# let the most ordinary way to name a PR from outside its checkout walk
# straight past the block. Knowing which flags take a value would mean knowing
# each CLI, which is the coupling this guard exists to avoid.
#
# The cost is a command that happens to pass the blocked words as consecutive
# values - `--title pr --body merge` - being refused. That is a loud refusal
# with a message saying why, against a merge going through unnoticed, so it is
# the direction to be wrong in.
plain=()
for arg in "$@"; do
    case "$arg" in -*) continue ;; esac
    plain+=("$arg")
done

n="${#plain[@]}"
m="${#want[@]}"
i=0
while [ "$((i + m))" -le "$n" ]; do
    k=0
    while [ "$k" -lt "$m" ] && [ "${plain[$((i + k))]}" = "${want[$k]}" ]; do
        k=$((k + 1))
    done
    [ "$k" -lt "$m" ] || break
    i=$((i + 1))
done
[ "$((i + m))" -le "$n" ] || exec "$real" "$@"

echo "Blocked by dejima's forge guard: merging is a human decision in the sandbox - open a PR/MR, then the operator merges. Report its URL and stop." >&2
exit 1
