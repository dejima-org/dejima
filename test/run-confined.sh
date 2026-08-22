#!/bin/bash
# Every confined suite at once, for the case where the whole set is genuinely
# wanted - before opening a pull request, or after touching bin/dejima, which
# nearly every suite reads.
#
# The suites are separate files that share no state, which is what makes this
# safe: each writes into its own BATS_*_TMPDIR, and the two that bind a socket
# ask the kernel for a free port rather than naming one. Run sequentially they
# take about twenty-five minutes on ten cores; run together, about seven, which
# is the difference between checking the whole set and not bothering.
#
# CI does not use this. It runs the same suites as a matrix, one job each, so
# that a failure names the suite it came from without anyone reading a log -
# see .gitea/workflows/tests.yml. This is the local equivalent.
#
# The list is discovered, so a suite added under test/ is picked up the day it
# lands. Only the privileged ones are named, because "needs a live Docker" is
# not visible in the filename.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root" || exit 1

# runtime.bats builds the image and boots containers; ci-runner.bats asserts
# against a real runner. Neither can run in a dejima sandbox, which is where
# this repo is usually worked on.
PRIVILEGED=" runtime ci-runner "

suites=()
for f in test/*.bats; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .bats)"
    case "$PRIVILEGED" in *" $name "*) continue ;; esac
    suites+=("$name")
done
[ "${#suites[@]}" -gt 0 ] || { echo "found no confined suites under test/" >&2; exit 1; }

# One process per suite. There are fewer suites than cores on anything this
# repo is developed on, and they are shell rather than CPU-bound, so a job
# limit would cost wall clock for no benefit.
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
for s in "${suites[@]}"; do
    ( bats "test/$s.bats" > "$out/$s" 2>&1; printf '%s' "$?" > "$out/$s.status" ) &
done
wait

# Counted from the TAP output rather than taken from the exit status alone: a
# suite that fails to run at all - a syntax error, or duplicate test names,
# which bats refuses outright - exits nonzero having run nothing, and reporting
# that as "0 failures" is how a green board comes to mean nothing.
failed=0
printf '%-16s %6s %8s\n' suite ran failed
for s in "${suites[@]}"; do
    ran="$(grep -cE '^(ok|not ok)' "$out/$s")"
    bad="$(grep -cE '^not ok' "$out/$s")"
    status="$(cat "$out/$s.status" 2>/dev/null || echo 1)"
    printf '%-16s %6s %8s' "$s" "$ran" "$bad"
    if [ "$ran" -eq 0 ]; then
        printf '   <- ran nothing\n'
        failed=1
    elif [ "$bad" -gt 0 ] || [ "$status" -ne 0 ]; then
        printf '\n'
        failed=1
    else
        printf '\n'
    fi
done

if [ "$failed" -ne 0 ]; then
    echo
    for s in "${suites[@]}"; do
        ran="$(grep -cE '^(ok|not ok)' "$out/$s")"
        bad="$(grep -cE '^not ok' "$out/$s")"
        { [ "$bad" -gt 0 ] || [ "$ran" -eq 0 ]; } || continue
        echo "--- $s"
        if [ "$ran" -eq 0 ]; then
            head -20 "$out/$s"
        else
            grep -E '^not ok' -A 6 "$out/$s"
        fi
        echo
    done
fi
exit "$failed"
