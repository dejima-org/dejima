#!/bin/bash
# Shadows a forge CLI on PATH, so that three rules hold whatever ran it: the
# one subcommand a workflow blocks is refused, a command aimed at another
# repository is refused, and a body the session authored says so.
#
# The first rule is the one hooks/merge-guard.sh applies - a merge is the
# operator's decision, so the sandbox opens a PR and stops - moved off the
# harness's hook protocol and onto the command. It works for a harness that
# cannot intercept a tool call, and it compares argv rather than
# regex-matching a command string, so quoting, spacing and pipelines stop
# mattering.
#
# The second is here for the same reason it is not in the forge CLIs: dejima
# writes two of them and not the third, so a disclosure living in the tools is
# one that depends on which forge an operator picked. This is the one place
# every forge passes through.
#
# Fast-fail, not a boundary, exactly as the hook was: what actually decides
# whether a merge is possible is the scope of the token the forge issued. This
# stops an eager agent doing it by accident.
#
#   DEJIMA_MERGE_BLOCK   the full command prefix to refuse, e.g. "gitea-pr
#                        merge". Its first word is the command this shadows;
#                        the rest is the subcommand sequence being refused.
#   DEJIMA_DISCLOSE      one record per line, "<kind> <command prefix>", e.g.
#                        "pr gitea-pr create". Both are resolved host-side by
#                        bin/dejima from the forge's manifest, never hardcoded
#                        to a forge here.
#   DEJIMA_FORGE_REPO    the "<owner>/<name>" of the repository the session
#                        was launched against, and DEJIMA_FORGE_REPO_FLAGS /
#                        DEJIMA_FORGE_REPO_ENV the spellings this forge's CLI
#                        accepts for naming a different one.
#   DEJIMA_FORGE_REAL_DIR  where the real CLIs live, behind the shadow.
set -u

self="$(basename "$0")"
real="${DEJIMA_FORGE_REAL_DIR:-/usr/local/lib/dejima/forge}/$self"

if [ ! -x "$real" ]; then
    echo "dejima: no forge CLI at '$real' for '$self'." >&2
    exit 127
fi

# Outside a dejima container, or with nothing to do, this is a pass-through.
if [ -z "${DEJIMA:-}" ] ||
   { [ -z "${DEJIMA_MERGE_BLOCK:-}" ] && [ -z "${DEJIMA_DISCLOSE:-}" ] &&
     [ -z "${DEJIMA_FORGE_REPO_FLAGS:-}" ] && [ -z "${DEJIMA_FORGE_REPO_ENV:-}" ]; }; then
    exec "$real" "$@"
fi

# The words of a command prefix, minus the CLI name, appear as a run of
# consecutive non-flag arguments. Flags are dropped first, so `gitea-pr
# --verbose merge 7` is still a merge.
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
plain=()
for arg in "$@"; do
    case "$arg" in -*) continue ;; esac
    plain+=("$arg")
done

# argv_has <word>... - true when those words appear consecutively in `plain`.
argv_has() {
    local want=("$@") n="${#plain[@]}" m="$#" i=0 k
    [ "$m" -gt 0 ] || return 1
    while [ "$((i + m))" -le "$n" ]; do
        k=0
        while [ "$k" -lt "$m" ] && [ "${plain[$((i + k))]}" = "${want[$k]}" ]; do
            k=$((k + 1))
        done
        [ "$k" -lt "$m" ] || return 0
        i=$((i + 1))
    done
    return 1
}

# --- the merge block --------------------------------------------------------

if [ -n "${DEJIMA_MERGE_BLOCK:-}" ]; then
    read -ra blocked <<< "$DEJIMA_MERGE_BLOCK"
    # The first word names the command; only the rest is a subcommand sequence
    # to compare against argv. A block naming a different command than the one
    # being run is not this invocation's business.
    if [ "${#blocked[@]}" -ge 1 ] && [ "${blocked[0]}" = "$self" ]; then
        if [ "${#blocked[@]}" -eq 1 ]; then
            # The whole command is blocked, not one of its subcommands.
            echo "Blocked by dejima's forge guard: '$self' is not available in the sandbox." >&2
            exit 1
        fi
        if argv_has "${blocked[@]:1}"; then
            echo "Blocked by dejima's forge guard: merging is a human decision in the sandbox - open a PR/MR, then the operator merges. Report its URL and stop." >&2
            exit 1
        fi
    fi
fi

# --- the repository the session was launched against ------------------------
#
# A forge whose CLI can be aimed elsewhere declares how (repo_flags,
# repo_env). The gitea CLIs declare neither, because they resolve the repo
# from origin and refuse another host; `gh` declares both, so on that path the
# most ordinary way to name a PR from outside its checkout is also the way to
# file an issue on a repository the session has nothing to do with (#187).
#
# Fast-fail, not a boundary, for the same reason the merge block is not one:
# the session holds the token and could call the API directly. What bounds
# this is the scope of push_token_file.
#
# Refused rather than skipped when the launch resolved no repository at all: a
# workspace with no origin has nothing for --repo to legitimately name, and
# "cannot confirm" is not a reason to let it through.
if [ -n "${DEJIMA_FORGE_REPO_FLAGS:-}" ] || [ -n "${DEJIMA_FORGE_REPO_ENV:-}" ]; then
    refuse_repo() {
        echo "Blocked by dejima's forge guard: this session was launched against ${DEJIMA_FORGE_REPO:-no repository}, and $1 names '$2'. Act on the repository the sandbox mounts." >&2
        exit 1
    }
    # Case-insensitively: forges treat an owner and a repository name as
    # case-preserving but not case-sensitive, and a refusal over capitalisation
    # would be a false one.
    same_repo() {
        [ -n "${DEJIMA_FORGE_REPO:-}" ] && [ "${1,,}" = "${DEJIMA_FORGE_REPO,,}" ]
    }
    if [ -n "${DEJIMA_FORGE_REPO_ENV:-}" ]; then
        env_value="${!DEJIMA_FORGE_REPO_ENV:-}"
        if [ -n "$env_value" ] && ! same_repo "$env_value"; then
            refuse_repo "$DEJIMA_FORGE_REPO_ENV" "$env_value"
        fi
    fi
    if [ -n "${DEJIMA_FORGE_REPO_FLAGS:-}" ]; then
        read -ra repo_flags <<< "$DEJIMA_FORGE_REPO_FLAGS"
        args_left=("$@")
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
                        # A one-dash flag may carry its value with no
                        # separator - `-Rowner/name` - which two-dash flags do
                        # not do.
                        case "$flag" in
                            --*) continue ;;
                            -?) ;;
                            *) continue ;;
                        esac
                        case "$arg" in "$flag"?*) value="${arg#"$flag"}" ;; *) continue ;; esac
                        ;;
                esac
                [ -n "$value" ] || continue
                same_repo "$value" || refuse_repo "$flag" "$value"
            done
        done
    fi
fi

# --- the authorship disclosure ---------------------------------------------

[ -n "${DEJIMA_DISCLOSE:-}" ] || exec "$real" "$@"

# The wording is core's, not any forge's, so that dejima says one thing about
# agent authorship however the session reached the forge. The kind is what a
# manifest picks per command.
marker_for() {
    case "$1" in
        pr)      printf '**Summary generated by LLM agent**' ;;
        issue)   printf '**Filed by LLM agent**' ;;
        comment) printf '**Comment by LLM agent**' ;;
    esac
}

kind=""
while read -r record_kind record_rest; do
    [ -n "$record_kind" ] || continue
    read -ra words <<< "$record_rest"
    [ "${#words[@]}" -ge 1 ] || continue
    [ "${words[0]}" = "$self" ] || continue
    if argv_has "${words[@]:1}"; then
        kind="$record_kind"
        break
    fi
done <<< "$DEJIMA_DISCLOSE"

[ -n "$kind" ] || exec "$real" "$@"

marker="$(marker_for "$kind")"
[ -n "$marker" ] || exec "$real" "$@"

# The body is rewritten into a temp file and the argument replaced with its
# path. That covers every spelling including `--body-file -`, where reading
# stdin here is the only way to prepend to it at all and the CLI behind this
# cannot read it twice. Turning --body-file into --body instead would put the
# whole body in argv, where a long one meets the 128KB per-argument limit.
#
# A command with no body argument is passed through untouched: there is
# nothing to disclose on. `gh pr create --fill` is that case - its body comes
# from commit messages, which are prose the session wrote somewhere else.
# The CLI behind this validates its own --body-file and then never gets the
# chance to: what reaches it is a temp file that always exists. So the check
# happens here instead, and refuses rather than sending something the operator
# did not write.
#
# Without it a mistyped path produced a PR whose entire body was the marker -
# created, not refused - and a --body-file naming something unreadable-forever
# (/dev/zero) filled a temp file until the disk did. Both are shapes the CLIs
# already refused before this shim stood in front of them.
body=""
read_body_or_die() {
    if [ "$1" = "-" ]; then
        body="$(cat)"
        return 0
    fi
    if [ ! -f "$1" ]; then
        echo "dejima: --body-file names something that is not a readable file: $1" >&2
        exit 1
    fi
    body="$(cat -- "$1")" || exit 1
}

# The body with the marker on it, whichever way the body arrived.
#
# One function for all four spellings, because there were two: --body-file
# went through here and --body prepended the marker inline at its own call
# site, so a rule added in one place was not in force in the other. That is
# the whole reason this exists as a function rather than as a printf repeated
# four times.
#
# Idempotent, which is the rule that was missing. An agent that has read the
# project's existing issues has seen every one of them open with this line,
# and writes it into the body itself - at which point a second was added and
# the artifact said it twice. Each doubled issue then taught the next agent to
# do the same, so it spread rather than settling.
#
# Skipping is safe because the marker is a statement, not a count: a body that
# already opens by saying an agent wrote it has disclosed exactly what this
# exists to disclose. Anchored at the start, after leading whitespace - the
# same words further down are prose ABOUT disclosure rather than the
# disclosure, and still get one prepended.
with_marker() {
    local head="${1#"${1%%[![:space:]]*}"}"
    case "$head" in
        "$marker"*) printf '%s' "$1"; return 0 ;;
    esac
    printf '%s\n\n%s' "$marker" "$1"
}

# The path to a temp file holding the disclosed body. Set outside the command
# substitution as well, so the caller can delete it afterwards.
tmp=""
disclosed() {
    tmp="$(mktemp)" || exit 1
    with_marker "$1" > "$tmp" || exit 1
}

# Only the first body argument is rewritten. A second would mean the CLI is
# being passed two, which is its own error to report.
args=()
rewrote=0
while [ "$#" -gt 0 ]; do
    if [ "$rewrote" = 0 ]; then
        case "$1" in
            --body-file)
                # Left alone when the value is missing: that is the CLI's
                # error to give, not this script's to pre-empt.
                if [ "$#" -ge 2 ]; then
                    read_body_or_die "$2"
                    disclosed "$body"
                    args+=(--body-file "$tmp")
                    rewrote=1
                    shift 2
                    continue
                fi
                ;;
            --body-file=*)
                read_body_or_die "${1#--body-file=}"
                disclosed "$body"
                args+=("--body-file=$tmp")
                rewrote=1
                shift
                continue
                ;;
            --body)
                if [ "$#" -ge 2 ]; then
                    args+=(--body "$(with_marker "$2")")
                    rewrote=1
                    shift 2
                    continue
                fi
                ;;
            --body=*)
                args+=("--body=$(with_marker "${1#--body=}")")
                rewrote=1
                shift
                continue
                ;;
        esac
    fi
    args+=("$1")
    shift
done

# Run rather than exec, only on this path: exec would replace this process and
# leave the temp file behind, and a body is not always small.
if [ -n "$tmp" ]; then
    "$real" "${args[@]}"
    status=$?
    rm -f "$tmp"
    exit "$status"
fi

exec "$real" "${args[@]}"
