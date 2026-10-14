#!/usr/bin/env bash
# PreToolUse hook: inside dejima, apply the forge policy to a forge CLI call -
# the merge a workflow blocks, and a command aimed at a repository the session
# was not launched against. What lands on the default branch is an operator
# decision, as it already is for `git push`; this is the API-side counterpart
# to git-push-guard.sh, since a merge reaches the branch without a push.
#
# The rules are docker/guard-lib.sh, which docker/forge-guard.sh applies to the
# same command as a PATH shadow. This file's job is to turn the command string
# a harness reports into the argv that library reads, so the two cannot reach
# different verdicts. Named for the merge block because that is the rule it was
# created for; the rest came with the shared policy.
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
# Fails OPEN - a forge that declares no policy has none blocked, rather than
# the hook guessing.

if [ -z "${DEJIMA:-}" ]; then
    exit 0
fi

if [ -z "${DEJIMA_MERGE_BLOCK:-}" ] && [ -z "${DEJIMA_DISCLOSE:-}" ] &&
   [ -z "${DEJIMA_FORGE_REPO_FLAGS:-}" ] && [ -z "${DEJIMA_FORGE_REPO_ENV:-}" ] &&
   [ -z "${DEJIMA_FORGE_REPO_PATHS:-}" ]; then
    exit 0
fi

command=$(jq -r '.tool_input.command // empty')

# shellcheck source=../docker/guard-lib.sh
source "${DEJIMA_GUARD_LIB:-/usr/local/lib/dejima/guard-lib.sh}"

forge_commands="$(dejima_forge_commands | sort -u)"
[ -n "$forge_commands" ] || exit 0

# Basenamed, so a path-qualified call is checked too - the Dockerfile installs
# each forge's CLI under /usr/local/bin, and the real one sits behind the
# shadow at a fixed path, which is what an agent reaching past a shadowed PATH
# would type. It is also what the shadow itself compares, since that reads its
# own basename.
#
# A later word counts only when it names a path, which is what divides the two
# layers: a bare `gh` anywhere in a segment is the shadow's, because reaching
# it means executing what PATH resolves, while a path names the real binary
# directly and the shadow never runs. `env /usr/local/lib/dejima/forge/gh pr
# merge 7` is both at once - a prefix word hiding the first position, and a
# path stepping over the shadow - so without the path case it belonged to
# neither. `echo gh pr merge 3` stays allowed, and must: it names the CLI
# without running it, and the shadow it would run is not being bypassed.
while IFS= read -r segment; do
    read -ra tokens <<< "$segment"
    for i in "${!tokens[@]}"; do
        case "$i:${tokens[$i]}" in
            0:*) ;;
            *:*/*) ;;
            *) continue ;;
        esac
        self="$(basename -- "${tokens[$i]}")"
        grep -qxF -- "$self" <<< "$forge_commands" || continue
        if ! dejima_forge_verdict "$self" "${tokens[@]:$((i + 1))}"; then
            echo "Blocked by merge-guard.sh: $DEJIMA_GUARD_REASON" >&2
            exit 2
        fi
    done
done < <(dejima_guard_segments "$command")

exit 0
