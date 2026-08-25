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
base="${1:-main}"
head="${2:-HEAD}"
# Guarded, because everything below is relative to it: a cd that failed
# silently would have this reporting on some other directory's suites and
# diff, which for a release gate is the worst way to be wrong.
cd "$root" || { echo "cannot enter $root" >&2; exit 1; }

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
new_providers=""
for pair in harnesses:harness forges:forge workflows:workflow; do
    axis="${pair%%:*}"
    one="${pair#*:}"
    [ -d "$axis" ] || continue
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        git cat-file -e "$base:$axis/$name/$one.conf" 2>/dev/null ||
            new_providers="$new_providers $one.$name"
    done < <(find "$axis" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
done

if [ -n "$added" ] || [ -n "$new_providers" ]; then
    [ -z "$added" ] || printf '   %s\n' $added
    [ -z "$new_providers" ] || printf '   [%s] as a config section\n' $new_providers
else
    echo "   (none - a rollback accepts any config this release accepts)"
fi

note "Then"
echo "   Say in the release PR what was run and what was not. A privileged job"
echo "   that queued is not a job that passed."
exit "$status"
