#!/bin/bash
# Shadows git on PATH so `git push` is checked whatever ran it.
#
# The rules are the ones hooks/git-push-guard.sh applies - push only to the
# forge's own hosts, never straight to a blocked branch - moved off the
# harness's hook protocol and onto the command itself. Two things follow from
# that. It works for a harness with no way to intercept a tool call, which is
# most of them. And it reads the decision out of argv rather than out of a
# regex over a reconstructed command string, so `git   push`, `git -c k=v
# push` and a push buried in a pipeline are all just argv here.
#
# It is a fast-fail guard, not a boundary, and the distinction is the same one
# docs/security.md draws about the hook it replaces: a session that means to
# get round it can call /usr/bin/git directly, exactly as it could have used a
# tool the hook did not cover. What stops a push reaching somewhere it should
# not is the firewall, and what stops it being accepted is the forge. This
# stops an eager agent doing the obvious thing by accident.
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

# Find the subcommand, and -C if it is there. git's own global options come
# before the subcommand and several take a value, so the ones that do are
# skipped in pairs rather than assumed to be attached.
repo_dir="$PWD"
subcommand=""
argv=("$@")
i=0
while [ "$i" -lt "${#argv[@]}" ]; do
    case "${argv[$i]}" in
        -C)
            i=$((i + 1))
            [ "$i" -lt "${#argv[@]}" ] && repo_dir="${argv[$i]}"
            ;;
        -c|--exec-path|--git-dir|--work-tree|--namespace|--super-prefix)
            i=$((i + 1))
            ;;
        -*)
            ;;
        *)
            subcommand="${argv[$i]}"
            break
            ;;
    esac
    i=$((i + 1))
done

[ "$subcommand" = "push" ] || exec "$REAL_GIT" "$@"

# What comes after `push`: the first two non-flag words are the remote and the
# refspec. Flags that take a value are skipped in pairs for the same reason as
# above - `git push --repo origin main` must not read "origin" as the remote.
# --repo names the remote in git's own legacy form and wins over a positional,
# so it is read rather than skipped: reading it as an opaque flag would leave
# `git push --repo=origin main` looking like a push to a remote called "main",
# which resolves to no URL - and passing that through unchecked is a push to
# origin/main that nothing looked at.
remote=""
refspec=""
i=$((i + 1))
while [ "$i" -lt "${#argv[@]}" ]; do
    case "${argv[$i]}" in
        --repo=*)
            remote="${argv[$i]#--repo=}"
            ;;
        --repo)
            i=$((i + 1))
            [ "$i" -lt "${#argv[@]}" ] && remote="${argv[$i]}"
            ;;
        -o|--push-option|--receive-pack|--exec)
            i=$((i + 1))
            ;;
        -*)
            ;;
        *)
            if [ -z "$remote" ]; then
                remote="${argv[$i]}"
            elif [ -z "$refspec" ]; then
                refspec="${argv[$i]}"
            fi
            ;;
    esac
    i=$((i + 1))
done
[ -n "$remote" ] || remote=origin

remote_url="$("$REAL_GIT" -C "$repo_dir" remote get-url "$remote" 2>/dev/null)"
# A remote this cannot resolve is refused rather than passed through. It is
# usually a typo, which git would reject in a moment anyway - but it is also
# what a disagreement between this parser and git's looks like, and the
# failure of that disagreement has to be a refusal rather than a push nobody
# checked.
if [ -z "$remote_url" ]; then
    echo "Blocked by dejima's git guard: cannot resolve the remote '$remote' to a URL," >&2
    echo "so there is nothing to check this push against. Name a remote that exists." >&2
    exit 1
fi

host="$(printf '%s' "$remote_url" \
    | sed -E 's#^[a-zA-Z]+://([^/@]+@)?([^/:]+).*#\2#; s#^[^@/]+@([^:/]+)[:/].*#\1#')"

host_allowed=0
for allowed_host in ${DEJIMA_PUSH_HOSTS:-}; do
    [ "$host" = "$allowed_host" ] && { host_allowed=1; break; }
done
if [ "$host_allowed" != 1 ]; then
    echo "Blocked by dejima's git guard: this sandbox may only push to ${DEJIMA_FORGE_NAME:-the configured forge}'s allowed host(s) (${DEJIMA_PUSH_HOSTS:-none allowed}), not '$host'." >&2
    exit 1
fi

if [ -n "$refspec" ]; then
    branch="${refspec##*:}"
else
    branch="$("$REAL_GIT" -C "$repo_dir" branch --show-current 2>/dev/null)"
fi
branch="${branch#refs/heads/}"

for blocked_branch in ${DEJIMA_BLOCKED_BRANCHES:-}; do
    if [ "$branch" = "$blocked_branch" ]; then
        echo "Blocked by dejima's git guard: direct pushes to '$branch' aren't allowed in the sandbox. Push a feature branch and open a PR/MR instead." >&2
        exit 1
    fi
done

exec "$REAL_GIT" "$@"
