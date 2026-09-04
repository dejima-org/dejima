#!/bin/bash
# The pre-release gate: everything that can be checked by running it, plus the
# list of what cannot, derived from what the release actually changes.
#
# Run before opening a development -> main pull request. It is deliberately not
# a CI job: half of what it produces is a list of things a person has to go and
# do, and a green tick nobody had to earn is worse than no tick.
#
# Usage: test/release-pass.sh [base] [head]     (defaults: main, HEAD)
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The remote-tracking ref by default, not the local branch. Everything this
# prints is derived from base..head - the manual checks from which paths the
# diff touches, the rollback list from which config keys it adds - so a base
# behind the real one silently reports a different release. That is not
# hypothetical: two passes ran against a local `main` 260 commits behind
# origin/main and reported keys and a trust-anchor domain that had shipped
# releases earlier. A gate answering confidently about the wrong diff is worse
# than one that does not run.
base="${1:-}"
if [ -z "$base" ]; then
    if git rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
        base=origin/main
    else
        base=main
    fi
fi
head="${2:-HEAD}"
# Guarded, because everything below is relative to it: a cd that failed
# silently would have this reporting on some other directory's suites and
# diff, which for a release gate is the worst way to be wrong.
cd "$root" || { echo "cannot enter $root" >&2; exit 1; }

# A named base that is behind its own upstream is refused rather than used.
# Passing `main` explicitly is the ordinary thing to do and is exactly how the
# stale-base runs happened, so this has to catch the argument as well as the
# default.
base_upstream="$(git rev-parse --abbrev-ref --symbolic-full-name "$base@{upstream}" 2>/dev/null || true)"
if [ -n "$base_upstream" ]; then
    behind="$(git rev-list --count "$base..$base_upstream" 2>/dev/null || echo 0)"
    if [ "${behind:-0}" -gt 0 ]; then
        echo "release-pass: '$base' is $behind commit(s) behind $base_upstream." >&2
        echo "Everything below is derived from $base..$head, so this would report on" >&2
        echo "a release that is not the one being made. Fetch, or name $base_upstream." >&2
        exit 1
    fi
fi

case "${1:-}" in
    -h|--help)
        echo "Usage: test/release-pass.sh [base] [head]"
        echo
        echo "Runs the gates that can be run here, then prints the manual checks"
        echo "the diff between base and head calls for. See docs/release.md."
        exit 0 ;;
esac

status=0
note() { printf '\n== %s\n' "$1"; }
fail() { printf '   NOT OK  %s\n' "$1"; status=1; }
pass() { printf '   ok      %s\n' "$1"; }

note "Confined suites"
if bash test/run-confined.sh; then
    pass "every confined suite"
else
    fail "confined suites"
fi

note "shellcheck"
# Captured rather than re-run, and the status kept in a variable rather than
# read off $? at a distance: 127 is "not installed", which is a different thing
# from "found faults" and must not be reported as either passing or failing the
# code.
shellcheck_out="$(bash test/shellcheck.sh 2>&1)"
shellcheck_rc=$?
if [ "$shellcheck_rc" = 0 ]; then
    pass "shellcheck"
elif [ "$shellcheck_rc" = 127 ]; then
    printf '%s\n' "$shellcheck_out"
    fail "shellcheck is not installed here - the gate did NOT run"
else
    printf '%s\n' "$shellcheck_out"
    fail "shellcheck found faults"
fi

note "Privileged suite"
if docker info >/dev/null 2>&1; then
    if bash -c 'bats test/runtime.bats'; then
        pass "test/runtime.bats"
    else
        fail "test/runtime.bats"
    fi
else
    fail "no Docker here - test/runtime.bats did NOT run"
    echo "           It is the only thing that exercises mounts, the firewall and"
    echo "           the entrypoint end to end. Run it on the host, or check that"
    echo "           the privileged CI job RAN rather than queued: it is pinned to"
    echo "           one self-hosted runner and queues silently when that is down."
fi

# --- what a person has to do, chosen by what the release touches -------------

changed="$(git diff --name-only "$base...$head" 2>/dev/null)" || changed=""
if [ -z "$changed" ]; then
    note "No diff between $base and $head - nothing to release."
    exit "$status"
fi

touches() { grep -qE "$1" <<< "$changed"; }

# Not a checklist to complete: an inventory of what nothing has checked. The
# gate for a release here is the security review plus the maintainer running
# the build - see docs/release.md. Printed anyway, because a release whose
# unverified paths are written down is one somebody can debug later.
note "Nothing has verified these, and this release touches them"
printed=0
manual() { printf '   -  %s\n' "$1"; printed=1; }

touches '^(bin/dejima$|docker/entrypoint|docker/Dockerfile|docker/docker-compose)' &&
    manual "Launch a real session. Nothing else exercises the mounts, the
       credential proxy and the exit audit together."
touches '^(forges/|bin/dejima-provider-lib|docker/forge-guard)' &&
    manual "Open a pull request through EVERY configured forge, and check the
       body that arrived. forge = github has never been run end to end."
touches '^(docker/git-guard|hooks/git-push-guard|hooks/merge-guard|docker/forge-guard)' &&
    manual "Try the thing the guard refuses, by the route an agent would take."
touches '^(bin/dejima-tty-suspend|bin/dejima$)' &&
    manual "Ctrl-Z a real session and fg it back: the terminal handling is
       tested against a stand-in, not against a real container run."
touches '^web/' &&
    manual "Load the page on a real phone. Nothing here can see a soft keyboard."
touches '^(harnesses/|bin/harness/|docker/harness-wrapper)' &&
    manual "Launch each affected harness against a real model."
touches '^(bin/dejima-attach|bin/dejima-ttyd|systemd/)' &&
    manual "Attach over the web front door and detach again."
touches '^tools/' &&
    manual "Launch with the affected tool included and use it. A tool is
       layered into the image and put on PATH; nothing here runs one."
touches '^\.dejima/allowed-domains$' &&
    manual "A domain here is read from main by the CI hardener and widens every
       future CI job on that runner. Say in the PR what it is for."
[ "$printed" = 1 ] || echo "   (none - this release touches nothing with a manual check)"

note "Required before this merges"
echo "   [ ] Security review of the whole $base...$head diff, against this"
echo "       project's own invariants - see docs/release.md. This is the gate."
echo "   [ ] Documentation review: every changed behaviour has its doc changed,"
echo "       and no doc describes something that no longer exists."
echo "   [ ] The maintainer runs the build: normal usage for a while, and a"
echo "       launch on the other configured harness to confirm it starts."

# A config key added in a release makes the PREVIOUS main refuse to start once
# an operator has adopted it, because an unknown key fails validation. That
# turns the obvious rollback into a second outage, so it is worth knowing
# before rather than after.
note "Config keys this release adds (a rollback refuses a config using them)"
added="$(comm -13 \
    <(git show "$base:bin/dejima-config-lib.sh" 2>/dev/null | grep -oE "^[a-z-]+\\.[a-z_]+" | sort -u) \
    <(grep -oE "^[a-z-]+\\.[a-z_]+" bin/dejima-config-lib.sh | sort -u))"
# Providers too, and this is the sharper half: a [harness.<name>] section for
# a harness the older dejima does not ship is an unknown SECTION, which fails
# validation exactly as an unknown key does. So adopting a new provider is
# itself the thing that makes the rollback refuse.
# The singular is spelled out rather than derived: "harnesses" does not lose
# an s to become "harness", and a manifest is named for the singular.
#
# Every axis there is, and the list is checked against the tree below rather
# than trusted: the newest axis is exactly the one a hand-kept list misses,
# because a list is only ever updated by whoever remembers. tools is an axis
# like the rest - `[core] tools = rtk` on a dejima that does not ship rtk is
# refused the same way an unknown harness is.
DEJIMA_RELEASE_AXES="harnesses:harness forges:forge workflows:workflow backends:backend tools:tool"
# The singular is spelled out above rather than derived - "harnesses" does not
# lose an s to become "harness", and a manifest is named for the singular - so
# this is the check that the spelling out has not fallen behind the tree.
for _d in */; do
    _d="${_d%/}"
    case "$_d" in
        harnesses|forges|workflows|backends|tools) ;;
        *) continue ;;
    esac
    case " $DEJIMA_RELEASE_AXES " in
        *" $_d:"*) ;;
        *) fail "$_d/ is a provider axis this script does not check for rollback" ;;
    esac
done

new_providers=""
for pair in $DEJIMA_RELEASE_AXES; do
    axis="${pair%%:*}"
    one="${pair#*:}"
    [ -d "$axis" ] || continue
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        git cat-file -e "$base:$axis/$name/$one.conf" 2>/dev/null ||
            new_providers="$new_providers $one.$name"
    done < <(find "$axis" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
done

# And the keys a provider DECLARES, which are config keys an operator writes
# and an older dejima refuses - but which live in a manifest rather than in
# core's schema, so the diff above cannot see them. `[harness.claude-code]
# backend` is one: adopting it is what makes the rollback refuse, and nothing
# said so.
new_keys=""
for pair in $DEJIMA_RELEASE_AXES; do
    axis="${pair%%:*}"
    one="${pair#*:}"
    [ -d "$axis" ] || continue
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        now="$(sed -n 's/^keys *= *//p' "$axis/$name/$one.conf" 2>/dev/null \
               | tr ' ' '\n' | sed 's/:.*//' | sort -u)"
        was="$(git show "$base:$axis/$name/$one.conf" 2>/dev/null \
               | sed -n 's/^keys *= *//p' | tr ' ' '\n' | sed 's/:.*//' | sort -u)"
        while IFS= read -r k; do
            [ -n "$k" ] || continue
            new_keys="$new_keys [$one.$name]|$k"
        done < <(comm -13 <(printf '%s\n' "$was") <(printf '%s\n' "$now"))
    done < <(find "$axis" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
done

if [ -n "$added" ] || [ -n "$new_providers" ] || [ -n "$new_keys" ]; then
    [ -z "$added" ] || printf '   %s\n' $added
    # How an older dejima refuses a new provider differs by axis, and saying
    # "as a config section" for all of them was wrong for tools: a tool has no
    # keys and so no section. It is refused through the value that names it.
    for entry in $new_providers; do
        case "$entry" in
            tool.*) printf '   [core] tools = %s\n' "${entry#tool.}" ;;
            *)      printf '   [%s] as a config section\n' "$entry" ;;
        esac
    done
    for entry in $new_keys; do
        printf '   %s %s\n' "${entry%%|*}" "${entry#*|}"
    done
else
    echo "   (none - a rollback accepts any config this release accepts)"
fi

note "Then"
echo "   Say in the release PR what was run and what was not. A privileged job"
echo "   that queued is not a job that passed."
exit "$status"
