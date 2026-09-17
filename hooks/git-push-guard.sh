#!/usr/bin/env bash
# PreToolUse hook: inside dejima, only allow `git push` to a host listed in
# DEJIMA_PUSH_HOSTS, and never directly to a branch listed in
# DEJIMA_BLOCKED_BRANCHES - both resolved host-side by bin/dejima from the
# configured forge and workflow (see dejima-provider-lib.sh), not hardcoded
# to any one forge. This is a fast-fail guard against an overeager agent,
# not a hard security boundary - a sandbox session has full shell access
# and could in principle edit .git/config or re-export these variables to
# route around it; that is true today and is not a regression, and the
# firewall (see docker/egress-policy) is the actual boundary. No-op outside the
# sandbox (DEJIMA unset), since this restriction doesn't apply to normal
# host usage.
#
# DEJIMA_PUSH_HOSTS fails CLOSED: empty means no host is allowed, so every
# push is refused. That is deliberate - it is how a no-forge or
# non-pushing workflow becomes enforced rather than merely described.
# DEJIMA_BLOCKED_BRANCHES fails OPEN: empty means no branch is protected,
# which is correct for a workflow that genuinely has no branch policy.

if [ -z "${DEJIMA:-}" ]; then
    exit 0
fi

input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')

# Only care about `git push` invocations - found by walking tokens rather than
# by matching a shape.
#
# The pattern this replaced recognised `git push` and `git -C <dir> push` and
# nothing else, so every other spelling of git's own options - `git -c k=v
# push`, `git --git-dir=... push`, `git --no-pager push` - was not a push as
# far as this hook was concerned, and it exited 0 before any check ran. The
# PATH shadow in docker/git-guard.sh walks argv and caught them regardless,
# which is why this was a quiet gap in the earlier warning rather than an open
# one.
#
# Split on the shell separators first, because a push can be the second half
# of a compound command, and only the segment that STARTS with git is a git
# invocation - "echo push" is not.
push_seen=0
segment=""
IFS=$'\n' read -rd '' -a _segments < <(
    printf '%s' "$command" | sed 's/&&/\n/g; s/||/\n/g; s/;/\n/g; s/|/\n/g'
    printf '\0')
for seg in ${_segments[@]+"${_segments[@]}"}; do
    read -ra _t <<< "$seg"
    [ "${#_t[@]}" -gt 0 ] || continue
    [ "${_t[0]}" = git ] || continue
    _i=1
    while [ "$_i" -lt "${#_t[@]}" ]; do
        case "${_t[$_i]}" in
            -c|-C|--exec-path|--git-dir|--work-tree|--namespace|--super-prefix)
                _i=$((_i + 1)) ;;
            -*) ;;
            push) push_seen=1; segment="$seg"; break ;;
            *) break ;;
        esac
        _i=$((_i + 1))
    done
    [ "$push_seen" -eq 1 ] && break
done
[ "$push_seen" -eq 1 ] || exit 0
# Everything below reads the git invocation, not the whole command line.
command="$segment"

repo_dir="$cwd"
if [[ "$command" =~ git[[:space:]]+-C[[:space:]]+([^[:space:]]+) ]]; then
    repo_dir="${BASH_REMATCH[1]}"
fi

# One pass over the whole command, the way the shadow walks argv: skip git's
# own options until the first token that IS the subcommand, then take the
# first non-flag token as the remote and the second as the refspec.
#
# Splitting on the first occurrence of the substring "push" is what this
# replaced, and it split inside `remote.origin.pushurl=...`, a branch named
# push-fix, and anything else carrying the word. What came out was a nonsense
# remote, which then took the unresolvable path below.
#
# Word-splitting rather than a full shell parse, so quoting edge cases are not
# handled - the same pragmatic tradeoff as the sibling
# deny-dangerous-bash.sh denylist, and the reason the unresolvable case
# refuses rather than guesses.
#
# `-c key=value` is kept rather than dropped: git resolves where a push goes
# from the config the push runs under, so asking without these answers for a
# different configuration. `git -c remote.origin.pushurl=... push origin
# branch` is that case.
config_overrides=()
positional=()
read -ra tokens <<< "$command"
t=0
seen_push=0
while [ "$t" -lt "${#tokens[@]}" ]; do
    tok="${tokens[$t]}"
    if [ "$seen_push" -eq 0 ]; then
        case "$tok" in
            -c) t=$((t + 1))
                [ "$t" -lt "${#tokens[@]}" ] && config_overrides+=(-c "${tokens[$t]}") ;;
            -C|--exec-path|--git-dir|--work-tree|--namespace|--super-prefix)
                t=$((t + 1)) ;;
            push) seen_push=1 ;;
            *) ;;
        esac
    else
        case "$tok" in
            -*) ;;
            *) positional+=("$tok") ;;
        esac
    fi
    t=$((t + 1))
done

remote="origin"
refspec=""
if [ "${#positional[@]}" -ge 1 ]; then
    remote="${positional[0]}"
fi
if [ "${#positional[@]}" -ge 2 ]; then
    refspec="${positional[1]}"
fi

# --push: the URL the push will actually use. remote.<name>.pushurl wins over
# remote.<name>.url when it is set, and reading the latter checks a host the
# push is not going to. See docker/git-guard.sh, which asks the same question.
remote_url=$(git ${config_overrides[@]+"${config_overrides[@]}"} \
    -C "$repo_dir" remote get-url --push "$remote" 2>/dev/null)
if [ -z "$remote_url" ]; then
    # Refused, not passed through. A remote that does not resolve is usually a
    # typo git would reject in a moment anyway - but it is also what a
    # disagreement between this parser and git's own looks like, and the
    # failure of that disagreement has to be a refusal rather than a push
    # nobody checked. docker/git-guard.sh takes the same direction; the two
    # answering differently was the bug.
    echo "Blocked by git-push-guard.sh: cannot resolve the remote '$remote' to a URL, so there is nothing to check this push against. Name a remote that exists." >&2
    exit 2
fi

host=$(echo "$remote_url" | sed -E 's#^[a-zA-Z]+://([^/@]+@)?([^/:]+).*#\2#; s#^[^@/]+@([^:/]+)[:/].*#\1#')

host_allowed=0
for allowed_host in ${DEJIMA_PUSH_HOSTS:-}; do
    if [ "$host" = "$allowed_host" ]; then
        host_allowed=1
        break
    fi
done

if [ "$host_allowed" != 1 ]; then
    echo "Blocked by git-push-guard.sh: this sandbox may only push to ${DEJIMA_FORGE_NAME:-the configured forge}'s allowed host(s) (${DEJIMA_PUSH_HOSTS:-none allowed}), not '$host'." >&2
    exit 2
fi

# Resolve the target branch: a src:dst refspec's dst, a bare branch name, or
# (if no refspec was given at all, or it's HEAD) the current branch - `git
# push origin` and `git push origin HEAD` both push the current branch.
if [[ "$refspec" == *:* ]]; then
    branch="${refspec#*:}"
elif [ -n "$refspec" ] && [ "$refspec" != "HEAD" ]; then
    branch="$refspec"
else
    branch=$(git -C "$repo_dir" branch --show-current 2>/dev/null)
fi
branch="${branch#refs/heads/}"

for blocked_branch in ${DEJIMA_BLOCKED_BRANCHES:-}; do
    if [ "$branch" = "$blocked_branch" ]; then
        echo "Blocked by git-push-guard.sh: direct pushes to '$branch' aren't allowed in the sandbox. Push a feature branch and open a PR/MR instead." >&2
        exit 2
    fi
done

exit 0
