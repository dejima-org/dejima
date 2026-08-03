#!/usr/bin/env bash
# PreToolUse hook: inside dejima, only allow `git push` to a host listed in
# DEJIMA_PUSH_HOSTS, and never directly to a branch listed in
# DEJIMA_BLOCKED_BRANCHES - both resolved host-side by bin/dejima from the
# configured forge and workflow (see dejima-provider-lib.sh), not hardcoded
# to any one forge. This is a fast-fail guard against an overeager agent,
# not a hard security boundary - a sandbox session has full shell access
# and could in principle edit .git/config or re-export these variables to
# route around it; that is true today and is not a regression, and the
# firewall (see init-firewall.sh) is the actual boundary. No-op outside the
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

# Only care about `git push` invocations.
if ! [[ "$command" =~ (^|[[:space:]&\|;])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push([[:space:]]|$) ]]; then
    exit 0
fi

repo_dir="$cwd"
if [[ "$command" =~ git[[:space:]]+-C[[:space:]]+([^[:space:]]+) ]]; then
    repo_dir="${BASH_REMATCH[1]}"
fi

# Positionally parse everything after "push": first non-flag token is the
# remote, second (if any) is the refspec. Word-splitting rather than a full
# shell parse, so quoting edge cases aren't handled - same pragmatic
# tradeoff as the sibling deny-dangerous-bash.sh denylist.
after_push="${command#*push}"
read -ra tokens <<< "$after_push"
positional=()
for tok in "${tokens[@]}"; do
    case "$tok" in
        -*) continue ;;
        *) positional+=("$tok") ;;
    esac
done

remote="origin"
refspec=""
if [ "${#positional[@]}" -ge 1 ]; then
    remote="${positional[0]}"
fi
if [ "${#positional[@]}" -ge 2 ]; then
    refspec="${positional[1]}"
fi

remote_url=$(git -C "$repo_dir" remote get-url "$remote" 2>/dev/null)
if [ -z "$remote_url" ]; then
    # Can't resolve a remote from here - let git produce the real error
    # rather than block or guess.
    exit 0
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
