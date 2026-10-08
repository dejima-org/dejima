#!/bin/bash
# The push and merge policy, once, for the two layers that apply it.
#
# Each rule used to exist twice: as a PATH shadow over the command
# (docker/git-guard.sh, docker/forge-guard.sh) and as a PreToolUse hook over
# the command string a harness reports (hooks/git-push-guard.sh,
# hooks/merge-guard.sh). The two overlap deliberately - a hook sees
# `/usr/bin/git push`, which walks past the shadow, and a shadow sees a push
# from an editor integration or a script, which the harness never reports - so
# neither can be dropped. What they cannot do is disagree, and they had already
# drifted: `git push -o x origin main` was fine to one and a hard refusal from
# the other, for the same invocation in the same session.
#
# So the decision lives here and both call it. A bypass is then fixed once.
#
# Every function reads argv, never a command string. A hook holds a string, so
# it splits it into segments and words first (dejima_guard_segments) and hands
# the words over - which is also why the hooks inherit the shadows' indifference
# to spacing, quoting and pipelines.
#
# None of this is a boundary, and the distinction is the one docs/security.md
# draws: a session that means to get round these can call /usr/bin/git or the
# forge API directly. What stops a push reaching somewhere it should not is the
# firewall, and what stops it being accepted is the forge's token scope. These
# stop an eager agent doing the obvious thing by accident.
#
# Sourced, so nothing here exits: a refusal is a return of 1 with the reason in
# DEJIMA_GUARD_REASON. The caller supplies its own prefix, because an operator
# reading a refusal needs to know which layer spoke.

# The real git, never the shadow. The shadow passes a non-push through, so
# calling it would work - but it would also mean every question this asks git
# goes through a script that is asking git questions.
DEJIMA_GUARD_GIT="${DEJIMA_GUARD_GIT:-/usr/bin/git}"

DEJIMA_GUARD_REASON=""

# --- splitting a command string into git/forge invocations -------------------

# dejima_guard_segments <command string>
#
# One segment per line. A guarded command can be the second half of a compound
# one, and only a segment whose first word is the command in question is that
# command - `echo push` is not a push.
#
# Word-splitting rather than a full shell parse, so quoting edge cases are not
# handled. That is the same pragmatic tradeoff as the sibling
# deny-dangerous-bash.sh denylist, and the reason every rule below refuses
# rather than guesses when it cannot read what it is looking at.
# The trailing newline is load-bearing: without it `read` returns false on the
# last segment even though it read one, so a command with no separators in it -
# every ordinary push - was never looked at.
dejima_guard_segments() {
    printf '%s\n' "$1" | sed 's/&&/\n/g; s/||/\n/g; s/;/\n/g; s/|/\n/g'
}

# --- git push ---------------------------------------------------------------

# Where a push will go and which branches it will write, read out of argv the
# way git reads it. Sets DEJIMA_GUARD_PUSH=1 when the argv is a push at all.
#
# git's own global options come before the subcommand and several take a
# separate value, so those are skipped in pairs rather than assumed attached.
#
# `-c key=value` is kept rather than skipped: git resolves where a push goes
# from the config the push runs under, so asking without these answers for a
# different configuration than the one about to be used. A one-command
# `-c remote.origin.pushurl=...` is exactly that case.
#
# --git-dir and --work-tree are REFUSED rather than skipped or honoured. Both
# used to be consumed and ignored, so `git --git-dir /tmp/x/.git push origin
# main` resolved `origin` in the mounted project, found it allowed, and then
# ran against a repository whose origin points somewhere else. Honouring them
# would mean reimplementing how they combine with -C and with each other;
# refusing is the direction the unresolvable-remote case below already takes,
# and a session with a second repository to push from can cd into it or use -C.
dejima_push_verdict() {  # <repo-dir> <git argv...>
    local repo_dir="$1"; shift
    local argv=("$@") i=0 subcommand="" branch
    local -a config_overrides=() refspecs=()
    local remote="" repo_flag="" push_all=0 push_mirror=0 repo_override=0
    DEJIMA_GUARD_REASON=""
    DEJIMA_GUARD_PUSH=0

    while [ "$i" -lt "${#argv[@]}" ]; do
        case "${argv[$i]}" in
            -C)
                i=$((i + 1))
                [ "$i" -lt "${#argv[@]}" ] && repo_dir="${argv[$i]}"
                ;;
            -c)
                i=$((i + 1))
                [ "$i" -lt "${#argv[@]}" ] \
                    && config_overrides+=(-c "${argv[$i]}")
                ;;
            --git-dir|--work-tree)
                repo_override=1
                i=$((i + 1))
                ;;
            --git-dir=*|--work-tree=*)
                repo_override=1
                ;;
            --exec-path|--namespace|--super-prefix)
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

    [ "$subcommand" = push ] || return 0
    DEJIMA_GUARD_PUSH=1

    # Noted while parsing and refused here, so that only a push is refused:
    # these say nothing about any other git command, and a guard that refused
    # `git --git-dir X status` would be refusing the flag rather than the push.
    if [ "$repo_override" = 1 ]; then
        DEJIMA_GUARD_REASON="a push carrying --git-dir or --work-tree cannot be checked, because the repository it writes from is not the one this would resolve the remote in. Run it from that repository, or name it with -C."
        return 1
    fi

    # What comes after `push`. --repo names the remote in git's own legacy form
    # and is read rather than treated as an opaque flag, because skipping it
    # would leave `git push --repo=origin main` looking like a bare push and
    # resolve a remote the command never named.
    #
    # It LOSES to a positional, which is what git documents: "this option is
    # equivalent to the <repository> argument. If both are specified, the
    # command-line argument takes precedence." Reading it the other way round
    # meant `git push --repo=origin other-remote feature` was checked against
    # origin and pushed to other-remote, whose host nothing had looked at.
    #
    # Every positional after the remote is a refspec, not just the first.
    # `git push origin feature main` checked `feature` alone and let `main`
    # through beside it.
    i=$((i + 1))
    while [ "$i" -lt "${#argv[@]}" ]; do
        case "${argv[$i]}" in
            --repo=*) repo_flag="${argv[$i]#--repo=}" ;;
            --repo)
                i=$((i + 1))
                [ "$i" -lt "${#argv[@]}" ] && repo_flag="${argv[$i]}"
                ;;
            --all) push_all=1 ;;
            --mirror) push_mirror=1 ;;
            -o|--push-option|--receive-pack|--exec)
                i=$((i + 1))
                ;;
            -*) ;;
            *)
                if [ -z "$remote" ]; then
                    remote="${argv[$i]}"
                else
                    refspecs+=("${argv[$i]}")
                fi
                ;;
        esac
        i=$((i + 1))
    done
    [ -n "$remote" ] || remote="$repo_flag"
    [ -n "$remote" ] || remote=origin

    # --push, because that is the URL the push will use. Without it this reads
    # remote.<name>.url while git pushes to remote.<name>.pushurl when one is
    # set, so a pushurl naming any other host is checked against the fetch URL
    # and allowed. It needs no evasion to reach: `git -c
    # remote.origin.pushurl=... push origin branch` sets one for a single
    # command, and .git/config is in the read-write project mount, so a session
    # can also just write one down.
    local remote_url host
    remote_url="$("$DEJIMA_GUARD_GIT" ${config_overrides[@]+"${config_overrides[@]}"} \
        -C "$repo_dir" remote get-url --push "$remote" 2>/dev/null)"
    if [ -z "$remote_url" ]; then
        # A remote this cannot resolve is refused rather than passed through.
        # It is usually a typo, which git would reject in a moment anyway - but
        # it is also what a disagreement between this parser and git's looks
        # like, and the failure of that disagreement has to be a refusal rather
        # than a push nobody checked.
        DEJIMA_GUARD_REASON="cannot resolve the remote '$remote' to a URL, so there is nothing to check this push against. Name a remote that exists."
        return 1
    fi

    host="$(printf '%s' "$remote_url" \
        | sed -E 's#^[a-zA-Z]+://([^/@]+@)?([^/:]+).*#\2#; s#^[^@/]+@([^:/]+)[:/].*#\1#')"

    local allowed_host host_allowed=0
    for allowed_host in ${DEJIMA_PUSH_HOSTS:-}; do
        [ "$host" = "$allowed_host" ] && { host_allowed=1; break; }
    done
    if [ "$host_allowed" != 1 ]; then
        DEJIMA_GUARD_REASON="this sandbox may only push to ${DEJIMA_FORGE_NAME:-the configured forge}'s allowed host(s) (${DEJIMA_PUSH_HOSTS:-none allowed}), not '$host'."
        return 1
    fi

    # --mirror puts every ref under refs/ on the remote AND deletes the ones
    # that are gone locally, so what it does to a protected branch cannot be
    # read off the command: a mirror from a checkout that has no `main` deletes
    # the remote's. Refused outright rather than resolved, because there is no
    # branch list that makes it safe.
    if [ "$push_mirror" = 1 ]; then
        DEJIMA_GUARD_REASON="--mirror writes every ref and deletes the remote refs this checkout does not have, so it cannot be checked against a branch policy. Push the branch you mean."
        return 1
    fi

    # --all pushes every local branch, so every local branch is what the policy
    # has to be applied to. The refspec list is empty here - git refuses --all
    # with one - and reading only the current branch is what let `git push
    # --all origin` from a feature branch push `main` beside it.
    if [ "$push_all" = 1 ]; then
        local local_branch
        while IFS= read -r local_branch; do
            [ -n "$local_branch" ] || continue
            if _dejima_branch_blocked "$local_branch"; then
                DEJIMA_GUARD_REASON="--all pushes every local branch, and '$local_branch' is one of them. Direct pushes to '$local_branch' aren't allowed in the sandbox. Push a feature branch and open a PR/MR instead."
                return 1
            fi
        done < <("$DEJIMA_GUARD_GIT" -C "$repo_dir" for-each-ref \
                    --format='%(refname:short)' refs/heads/ 2>/dev/null)
        return 0
    fi

    # Each refspec's destination. `src:dst` names it outright, a bare name is
    # both, and `HEAD` or no refspec at all means the current branch - `git
    # push origin` and `git push origin HEAD` both push it.
    if [ "${#refspecs[@]}" -eq 0 ]; then
        refspecs=(HEAD)
    fi
    local refspec
    for refspec in "${refspecs[@]}"; do
        # One leading `+` is the force marker, and it belongs to the refspec
        # rather than to the branch - so `git push origin +main` names main and
        # was compared as "+main", which matched no policy entry. The escaping
        # form was the destructive one.
        refspec="${refspec#+}"
        case "$refspec" in
            *:*) branch="${refspec##*:}" ;;
            HEAD) branch="$("$DEJIMA_GUARD_GIT" -C "$repo_dir" branch --show-current 2>/dev/null)" ;;
            *) branch="$refspec" ;;
        esac
        branch="${branch#refs/heads/}"
        if _dejima_branch_blocked "$branch"; then
            DEJIMA_GUARD_REASON="direct pushes to '$branch' aren't allowed in the sandbox. Push a feature branch and open a PR/MR instead."
            return 1
        fi
    done

    return 0
}

# DEJIMA_BLOCKED_BRANCHES fails OPEN: empty means no branch is protected, which
# is correct for a workflow that genuinely has no branch policy. Unlike
# DEJIMA_PUSH_HOSTS above, which fails CLOSED - empty means no host is allowed,
# so every push is refused, and that is how a no-forge or non-pushing workflow
# becomes enforced rather than merely described.
_dejima_branch_blocked() {
    local blocked
    [ -n "${1:-}" ] || return 1
    for blocked in ${DEJIMA_BLOCKED_BRANCHES:-}; do
        [ "$1" = "$blocked" ] && return 0
    done
    return 1
}

# --- the forge CLI ----------------------------------------------------------

# dejima_argv_has <word>... - true when those words appear consecutively among
# the non-flag arguments of the command being checked. _dejima_plain must be
# set first, by dejima_forge_verdict.
#
# Anywhere in that run rather than at the start of it, because a flag's value
# is indistinguishable from a subcommand here: in `gh --repo o/r pr merge 7`
# the first non-flag argument is `o/r`, and requiring the match to begin there
# let the most ordinary way to name a PR from outside its checkout walk
# straight past the block. Knowing which flags take a value would mean knowing
# each CLI, which is the coupling this guard exists to avoid.
#
# The cost is a command that happens to pass the words as consecutive values -
# `--title pr --body merge` - matching. For the merge block that is a loud
# refusal against a merge going through unnoticed; for a disclosure it is a
# line of text on something an agent did write anyway. Both are the direction
# to be wrong in.
dejima_argv_has() {
    local want=("$@") n="${#_dejima_plain[@]}" m="$#" i=0 k
    [ "$m" -gt 0 ] || return 1
    while [ "$((i + m))" -le "$n" ]; do
        k=0
        while [ "$k" -lt "$m" ] && [ "${_dejima_plain[$((i + k))]}" = "${want[$k]}" ]; do
            k=$((k + 1))
        done
        [ "$k" -lt "$m" ] || return 0
        i=$((i + 1))
    done
    return 1
}

# dejima_forge_plain <argv...> - fills _dejima_plain with the non-flag
# arguments, which is what every rule below compares against.
dejima_forge_plain() {
    local arg
    _dejima_plain=()
    for arg in "$@"; do
        case "$arg" in -*) continue ;; esac
        _dejima_plain+=("$arg")
    done
}

# dejima_forge_commands - every CLI this policy applies to, one per line: the
# one whose merge a workflow blocks, and every one that writes a body the
# session authored. More than one, because a forge can have a CLI per artifact
# rather than one with subcommands, and because a forge with nothing blocked
# can still have something to disclose.
#
# docker/entrypoint.sh links the shadow over exactly this set, and
# hooks/merge-guard.sh checks a command against it before applying anything -
# without that the hook would apply gh's --repo rule to any command carrying
# that flag, which the shadow cannot do because it only exists for these.
dejima_forge_commands() {
    [ -z "${DEJIMA_MERGE_BLOCK:-}" ] || printf '%s\n' "${DEJIMA_MERGE_BLOCK%% *}"
    # "<kind> <cli> <subcommand>...", so the CLI is the second word.
    [ -z "${DEJIMA_DISCLOSE:-}" ] || printf '%s\n' "$DEJIMA_DISCLOSE" |
        while read -r _ _cli _; do
            [ -z "$_cli" ] || printf '%s\n' "$_cli"
        done
}

# dejima_forge_verdict <command name> <argv...>
#
# The command name is argv[0] as the caller saw it - the shadow's own basename,
# or the first word of a hook's segment. Every policy here is keyed to it,
# because a block naming a different command than the one being run is not this
# invocation's business.
dejima_forge_verdict() {
    local self="$1"; shift
    DEJIMA_GUARD_REASON=""
    dejima_forge_plain "$@"

    if [ -n "${DEJIMA_MERGE_BLOCK:-}" ]; then
        local -a blocked
        read -ra blocked <<< "$DEJIMA_MERGE_BLOCK"
        if [ "${#blocked[@]}" -ge 1 ] && [ "${blocked[0]}" = "$self" ]; then
            if [ "${#blocked[@]}" -eq 1 ]; then
                # The whole command is blocked, not one of its subcommands.
                DEJIMA_GUARD_REASON="'$self' is not available in the sandbox."
                return 1
            fi
            if dejima_argv_has "${blocked[@]:1}"; then
                DEJIMA_GUARD_REASON="merging is a human decision in the sandbox - open a PR/MR, then the operator merges. Report its URL and stop."
                return 1
            fi
        fi
    fi

    _dejima_forge_repo_verdict "$@" || return 1
    return 0
}

# The repository the session was launched against.
#
# A forge whose CLI can be aimed elsewhere declares how (repo_flags, repo_env,
# repo_paths). The gitea CLIs declare none, because they resolve the repo from
# origin and refuse another host; `gh` declares all three, so on that path the
# most ordinary way to name a PR from outside its checkout is also the way to
# file an issue on a repository the session has nothing to do with (#187).
#
# Refused rather than skipped when the launch resolved no repository at all: a
# workspace with no origin has nothing for --repo to legitimately name, and
# "cannot confirm" is not a reason to let it through.
_dejima_forge_repo_verdict() {
    [ -n "${DEJIMA_FORGE_REPO_FLAGS:-}" ] || [ -n "${DEJIMA_FORGE_REPO_ENV:-}" ] \
        || [ -n "${DEJIMA_FORGE_REPO_PATHS:-}" ] || return 0

    if [ -n "${DEJIMA_FORGE_REPO_ENV:-}" ]; then
        local env_value="${!DEJIMA_FORGE_REPO_ENV:-}"
        if [ -n "$env_value" ] && ! _dejima_same_repo "$env_value"; then
            _dejima_refuse_repo "$DEJIMA_FORGE_REPO_ENV" "$env_value"
            return 1
        fi
    fi

    if [ -n "${DEJIMA_FORGE_REPO_FLAGS:-}" ]; then
        local -a repo_flags args_left
        read -ra repo_flags <<< "$DEJIMA_FORGE_REPO_FLAGS"
        args_left=("$@")
        local arg flag value letter rest
        while [ "${#args_left[@]}" -gt 0 ]; do
            arg="${args_left[0]}"
            args_left=("${args_left[@]:1}")
            for flag in "${repo_flags[@]}"; do
                value=""
                case "$arg" in
                    "$flag")
                        # The value is the next argument, and its absence is
                        # the CLI's error to report rather than this one's.
                        [ "${#args_left[@]}" -gt 0 ] || continue
                        value="${args_left[0]}"
                        ;;
                    "$flag"=*) value="${arg#*=}" ;;
                    *)
                        # One-dash flags only; a two-dash flag carries its
                        # value with `=` or as the next argument, both above.
                        case "$flag" in
                            -?) ;;
                            *) continue ;;
                        esac
                        # Short flags cluster, so the letter can sit anywhere
                        # in one: `-Rowner/name`, `-wR owner/name` and
                        # `-wRowner/name` all name a repository and none of
                        # them is `-R` as its own argument (#243). Split at the
                        # letter the way getopt does - what follows it in the
                        # same argument is the value, and nothing following it
                        # means the next argument is.
                        letter="${flag#-}"
                        # A cluster, not a value that happens to start with a
                        # dash: one dash, then the letter somewhere in a run of
                        # letters. Without the second check, `--search foo-R/x`
                        # style arguments would be mined for flag letters.
                        case "$arg" in -[!-]*) ;; *) continue ;; esac
                        rest="${arg#-}"
                        case "$rest" in *"$letter"*) ;; *) continue ;; esac
                        case "${rest%%"$letter"*}" in *[!A-Za-z]*) continue ;; esac
                        value="${rest#*"$letter"}"
                        if [ -z "$value" ]; then
                            [ "${#args_left[@]}" -gt 0 ] || continue
                            value="${args_left[0]}"
                        fi
                        ;;
                esac
                [ -n "$value" ] || continue
                if ! _dejima_same_repo "$value"; then
                    _dejima_refuse_repo "$flag" "$value"
                    return 1
                fi
            done
        done
    fi

    _dejima_forge_path_verdict "$@" || return 1
    return 0
}

# A repository named in a path rather than in a flag - `gh api
# repos/<owner>/<name>/issues` reaches any repository the token does, without a
# --repo anywhere in it (#243).
#
# Only when the declared subcommand is argv's first word. The alternative is
# inspecting every positional that contains two slashes, which would refuse
# `gh issue create --title repos/a/b` - and a false refusal costs an honest
# agent a working command, which is the wrong way for a fast-fail to be wrong.
#
# Under that subcommand the rule is inverted: rather than looking for a path
# naming the wrong repository, it requires one naming the right one. `gh api`
# reaches every endpoint the token does, and an endpoint that is not under the
# declared segment - `user/repos`, `/orgs/<org>/repos`, `graphql` - names no
# repository for this to compare, so there was nothing to refuse and nothing
# was (#365). Telling an endpoint apart from a header value or a field value
# would mean knowing which of the CLI's flags take a separate value, which is
# the coupling this guard exists to avoid - so the question asked is whether a
# target it CAN read is present, which needs no such knowledge.
#
# graphql counts as one, because dejima's own github-pr reads review threads
# through it and the API has no other route to them. A mutation does not:
# `gh api graphql -f query='mutation{mergePullRequest(...)}'` is what an agent
# reaches for once `gh pr merge` refuses, and no repository scoping can be read
# out of a GraphQL document. Queries through it can only read, which the
# read-only token could do anyway.
_dejima_forge_path_verdict() {
    [ -n "${DEJIMA_FORGE_REPO_PATHS:-}" ] && [ "$#" -gt 0 ] || return 0

    local -a repo_paths
    read -ra repo_paths <<< "$DEJIMA_FORGE_REPO_PATHS"
    local spec segment arg path owner name scopable
    for spec in "${repo_paths[@]}"; do
        [ "$1" = "${spec%%:*}" ] || continue
        segment="${spec#*:}"
        scopable=0
        for arg in "$@"; do
            # A GraphQL document whose operation is a mutation. Matched
            # anywhere in the argument, because the document arrives as the
            # value of a field flag - `-f query=mutation{...}` - rather than as
            # an argument of its own. Matched before the brace test below,
            # which a document would otherwise satisfy.
            #
            # Over EVERY argument, including the dash-prefixed ones, because a
            # flag can carry its value attached: `--field=query=mutation{...}`
            # and `-Fquery=mutation{...}` put the document inside one word that
            # the scoping loop below skips. This check needs no flag table to
            # read it, which is what lets it look at all of them - unlike the
            # repository scoping, which does.
            #
            # Both boundaries are anything that cannot continue an
            # identifier, rather than whitespace and a brace. GraphQL treats
            # commas and comments as ignored tokens, so `mutation,{...}` and
            # `mutation#c` followed by the body are valid documents, and a
            # document carrying more than one operation puts `}` immediately
            # before the second one. Each of those sat just outside a narrower
            # boundary. The class excludes `_` on both sides, so a field called
            # foo_mutation is not a mutation.
            if [[ "$arg" =~ (^|[^A-Za-z0-9_])mutation([^A-Za-z0-9_]|$) ]]; then
                DEJIMA_GUARD_REASON="a GraphQL mutation reaches any repository and any write the token allows, and no repository scoping can be read out of it. Use the subcommands, and leave a merge to the operator."
                return 1
            fi
            # A body this cannot read is a body it cannot tell a query from a
            # mutation in. Two spellings put one out of reach: a field value
            # read from a file, and --input, which takes the whole request body
            # from a file or from stdin. Refused under this subcommand only;
            # the document is one argument, so passing it inline is the fix.
            case "$arg" in
                *=@*|--input|--input=*)
                    DEJIMA_GUARD_REASON="'$1' takes its body from a file or from stdin, so what it sends is not in the command for this to read. Pass the document inline."
                    return 1
                    ;;
            esac
            # Everything from here needs to know which argument is the
            # endpoint, so the flags go.
            case "$arg" in -*) continue ;; esac
            [ "$arg" = graphql ] && { scopable=1; continue; }
            # gh substitutes {owner} and {repo} from the checkout, so a path
            # carrying them names this repository by construction and comparing
            # the literal braces would refuse it.
            case "$arg" in *'{'*) scopable=1; continue ;; esac
            path="${arg#/}"
            case "$path" in "$segment"/*/*) ;; *) continue ;; esac
            path="${path#"$segment"/}"
            owner="${path%%/*}"
            path="${path#*/}"
            name="${path%%/*}"
            [ -n "$owner" ] && [ -n "$name" ] || continue
            if ! _dejima_same_repo "$owner/$name"; then
                _dejima_refuse_repo "the path '$arg'" "$owner/$name"
                return 1
            fi
            scopable=1
        done
        if [ "$scopable" = 0 ]; then
            DEJIMA_GUARD_REASON="'$1' names no endpoint under '$segment/', so there is nothing here saying which repository this reaches. Name the endpoint as '$segment/${DEJIMA_FORGE_REPO:-<owner>/<name>}/...', or use the subcommands."
            return 1
        fi
    done
    return 0
}

_dejima_refuse_repo() {
    DEJIMA_GUARD_REASON="this session was launched against ${DEJIMA_FORGE_REPO:-no repository}, and $1 names '$2'. Act on the repository the sandbox mounts."
}

# Case-insensitively: forges treat an owner and a repository name as
# case-preserving but not case-sensitive, and a refusal over capitalisation
# would be a false one.
_dejima_same_repo() {
    [ -n "${DEJIMA_FORGE_REPO:-}" ] && [ "${1,,}" = "${DEJIMA_FORGE_REPO,,}" ]
}
