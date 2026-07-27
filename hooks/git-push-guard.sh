#!/usr/bin/env bash
# PreToolUse hook: inside dejima, only allow `git push` to the Gitea
# host (GITEA_SSH_HOST / the GITEA_API host), and never directly to
# main/master there - the sandbox workflow is feature branch + `gitea-pr
# create`, never a direct push. GitHub push is also blocked here by default
# (on top of the firewall's own port-22 block - see init-firewall.sh), unless
# ALLOW_GITHUB_PUSH=1 is set, in which case github.com/ssh.github.com are
# also accepted push hosts - the no-direct-to-main rule still applies there
# too. This is a fast-fail guard against an overeager agent, not a hard
# security boundary - a sandbox session has full shell access and could in
# principle edit .git/config to route around it. No-op outside the sandbox
# (DEJIMA unset), since this restriction doesn't apply to normal host
# usage.

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

gitea_api_host=""
if [ -n "${GITEA_API:-}" ]; then
    gitea_api_host=$(echo "$GITEA_API" | sed -E 's#^[a-zA-Z]+://([^/]+).*#\1#')
fi

github_allowed=0
if [ "${ALLOW_GITHUB_PUSH:-0}" = "1" ] && { [ "$host" = "github.com" ] || [ "$host" = "ssh.github.com" ]; }; then
    github_allowed=1
fi

if [ "$host" != "${GITEA_SSH_HOST:-}" ] && [ "$host" != "$gitea_api_host" ] && [ "$github_allowed" != 1 ]; then
    echo "Blocked by git-push-guard.sh: this sandbox may only push to the Gitea host (${GITEA_SSH_HOST:-<GITEA_SSH_HOST not set>})$( [ "${ALLOW_GITHUB_PUSH:-0}" = "1" ] && echo " or github.com/ssh.github.com (ALLOW_GITHUB_PUSH=1)" ), not '$host'." >&2
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

if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
    echo "Blocked by git-push-guard.sh: direct pushes to '$branch' aren't allowed in the sandbox. Push a feature branch and run 'gitea-pr create' instead." >&2
    exit 2
fi

exit 0
