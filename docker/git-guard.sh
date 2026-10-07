#!/bin/bash
# Shadows git on PATH so `git push` is checked whatever ran it.
#
# The rules are in docker/guard-lib.sh, which hooks/git-push-guard.sh applies
# to the same push from the other side - push only to the forge's own hosts,
# never straight to a blocked branch. Here they sit on the command itself,
# which means two things. It works for a harness with no way to intercept a
# tool call, which is most of them. And it reads the decision out of argv
# rather than out of a regex over a reconstructed command string, so
# `git   push`, `git -c k=v push` and a push buried in a pipeline are all just
# argv here.
#
# It is a fast-fail guard, not a boundary, and the distinction is the same one
# docs/security.md draws about the hook beside it: a session that means to get
# round it can call /usr/bin/git directly, exactly as it could have used a tool
# the hook did not cover. What stops a push reaching somewhere it should not is
# the firewall, and what stops it being accepted is the forge.
#
# Everything it needs is already in the container's environment, resolved on
# the host from the forge and workflow manifests (see bin/dejima):
#
#   DEJIMA_PUSH_HOSTS        hosts this sandbox may push to, space separated
#   DEJIMA_BLOCKED_BRANCHES  branches it may not push straight to
#   DEJIMA_FORGE_NAME        only to name the forge in the refusal
set -u

REAL_GIT=/usr/bin/git

# Outside a dejima container this file should not exist, but if it is ever run
# there, do nothing rather than refuse: the guard is about the sandbox.
if [ -z "${DEJIMA:-}" ]; then
    exec "$REAL_GIT" "$@"
fi

DEJIMA_GUARD_GIT="$REAL_GIT"
# shellcheck source=guard-lib.sh
source "${DEJIMA_GUARD_LIB:-/usr/local/lib/dejima/guard-lib.sh}"

if ! dejima_push_verdict "$PWD" "$@"; then
    echo "Blocked by dejima's git guard: $DEJIMA_GUARD_REASON" >&2
    exit 1
fi

exec "$REAL_GIT" "$@"
