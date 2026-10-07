#!/usr/bin/env bash
# PreToolUse hook: inside dejima, only allow `git push` to a host listed in
# DEJIMA_PUSH_HOSTS, and never directly to a branch listed in
# DEJIMA_BLOCKED_BRANCHES - both resolved host-side by bin/dejima from the
# configured forge and workflow (see dejima-provider-lib.sh), not hardcoded
# to any one forge.
#
# The rules themselves are docker/guard-lib.sh, which docker/git-guard.sh
# applies to the same push as a PATH shadow. This file's whole job is to turn
# the command string a harness reports into the argv that library reads, so
# that the two cannot reach different verdicts - which they had already started
# to do.
#
# A fast-fail guard against an overeager agent, not a hard security boundary: a
# sandbox session has full shell access and could in principle edit .git/config
# or re-export these variables to route around it, and the firewall (see
# docker/egress-policy) is the actual boundary. No-op outside the sandbox
# (DEJIMA unset), since this restriction doesn't apply to normal host usage.

if [ -z "${DEJIMA:-}" ]; then
    exit 0
fi

input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')

# shellcheck source=../docker/guard-lib.sh
source "${DEJIMA_GUARD_LIB:-/usr/local/lib/dejima/guard-lib.sh}"

# A push can be the second half of a compound command, and only a segment whose
# first word is git is a git invocation. Every segment that is one gets the same
# verdict function the shadow calls, on the words after `git` - so a spelling
# this file does not recognise is not a spelling that goes unchecked: it is argv
# either way.
while IFS= read -r segment; do
    read -ra tokens <<< "$segment"
    [ "${#tokens[@]}" -gt 0 ] || continue
    [ "${tokens[0]}" = git ] || continue
    if ! dejima_push_verdict "$cwd" "${tokens[@]:1}"; then
        echo "Blocked by git-push-guard.sh: $DEJIMA_GUARD_REASON" >&2
        exit 2
    fi
done < <(dejima_guard_segments "$command")

exit 0
