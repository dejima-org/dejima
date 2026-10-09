#!/bin/bash
# The confined suites, in one of two lanes.
#
#   test/run-confined.sh              every confined suite - the pull-request gate
#   test/run-confined.sh --changed    only the suites the working diff calls for
#
# The suites are separate files that share no state, which is what makes running
# them together safe: each writes into its own BATS_*_TMPDIR, and the two that
# bind a socket ask the kernel for a free port rather than naming one. Within a
# file, bats' own --jobs parallelism is used too; it needs flock rather than GNU
# parallel, which is why --no-parallelize-across-files is passed alongside it
# (bats refuses --jobs without GNU parallel unless across-files is off, and this
# script is already doing the across-files half itself).
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

# Which suites a changed path calls for. This is the table .dejima.md used to
# carry as prose; it is here so that it runs, and so that an agent iterating
# cannot map a change to the wrong suite by hand.
#
# Anything that matches no rule selects every suite. A path nobody has mapped
# is a path nobody has decided about, and guessing "none" there is how a change
# ships having been checked by nothing.
suites_for() {
    # Every suite that READS the path, not the one that owns it. static.bats
    # asserts invariants over the whole tree and config.bats sources most of
    # the libraries, so both appear far more often than a by-area reading
    # suggests - and leaving them out is what made the --changed lane report an
    # edit as green from a selection that never loaded the file.
    #
    # The map is checked against the suites mechanically; see the test named
    # for it in static.bats. Over-selecting costs a suite run, under-selecting
    # costs a missed regression, so a rule here errs wide.
    case "$1" in
        # Read by nearly every other suite, so a change to one is the whole set.
        bin/dejima|bin/dejima-config-lib.sh) echo ALL ;;

        bin/dejima-audit)                    echo 'audit config proxy remote static' ;;
        bin/dejima-update-check)             echo 'config project remote static' ;;
        bin/dejima-epitaph)                  echo 'config static' ;;
        bin/dejima-tty-suspend)              echo static ;;
        bin/dejima-color-lib.sh)             echo 'remote project config static' ;;
        bin/dejima-tui-lib.sh)               echo 'remote project static' ;;
        bin/dejima-conversation-ship)        echo 'conversation static' ;;
        bin/dejima-share)                    echo 'share static' ;;
        # The slug scheme keys the transcript mounts, the epitaph and audit
        # stores, and the share layout, so a change to it is not one area's.
        bin/dejima-slug-lib.sh)              echo 'share conversation audit static' ;;
        bin/dejima-credential-proxy|docker/credential-proxy-forwarder.js) echo 'proxy static' ;;
        bin/dejima-credential-scan*)         echo 'config static' ;;
        bin/dejima-project-lib.sh|bin/dejima-project|bin/dejima-dep) \
            echo 'project config launch providers remote static' ;;
        bin/dejima-allow)                    echo 'project static config' ;;
        bin/dejima-attach)                   echo 'remote config project static' ;;
        bin/dejima-ttyd|bin/dejima-notify-watch) echo 'remote config static' ;;
        web/*|systemd/*)                     echo 'remote static' ;;
        bin/dejima-provider-lib.sh)          echo 'providers config remote share static' ;;
        bin/dejima-harness-lib.sh)           echo 'providers config remote static' ;;
        bin/harness/*)                       echo 'providers remote static' ;;
        # A manifest is read by more than the suite that owns the schema: the
        # audit reads a workflow's briefing, conversation.bats sed-injects a
        # harness.conf, and config.bats copies the whole set in.
        forges/*|workflows/*|harnesses/*|tools/*) \
            echo 'providers static audit config conversation' ;;
        install.sh)                          echo 'config audit providers remote static' ;;

        # static.bats asserts on files it does not own, so a shipped doc or a
        # docker/ file needs it as well as whatever else the change touched -
        # which for docker/ is most things, since the entrypoint and compose
        # file are read by nearly every suite that builds a launch.
        docker/*)                            echo ALL ;;
        hooks/*)                             echo 'static config providers project remote' ;;
        .gitea/*|.shellcheckrc)              echo static ;;
        .dejima/*)                           echo 'static config project providers' ;;

        # A suite file is read by static.bats as well as run by bats: it
        # asserts invariants over the text of the others, so an edit to one
        # that only selected itself was reported green by a lane that never
        # loaded the assertions about it.
        test/*.bats) local n="${1##*/}"; echo "${n%.bats} static" ;;
        # Fixtures are executed by the suites that consume them, not merely
        # read: fake-anthropic.py is the upstream in proxy.bats (and in
        # runtime.bats, which no confined selection can carry), and
        # answer-prompt.py drives config.bats' prompts.
        test/fixtures/*)                     echo 'proxy static config' ;;
        test/*)                              echo static ;;

        # Last of the specific rules, not before them: a .md under test/ or
        # .dejima/ belongs to whatever reads that directory, and this pattern
        # would otherwise answer for it. The docs themselves are asserted
        # against by more than static.bats - the README's axis lists, the
        # provider tables, the nginx example and the remote-access page each
        # have a suite checking the code agrees with them.
        #
        # So a doc-only edit runs more than static alone. That is the cost of
        # the lane answering for what reads a file, and it is the safe
        # direction: narrowing this back would report a doc change as green
        # from suites that assert against it.
        docs/*|README.md|*.md)               echo 'static config providers remote' ;;

        *) echo ALL ;;
    esac
}

lane=all
jobs=""
base=""
list_only=0
given_paths=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --changed) lane=changed ;;
        --base) shift; base="${1:-}" ;;
        --list) list_only=1 ;;
        -j|--jobs) shift; jobs="${1:-}" ;;
        -h|--help)
            sed -n '2,5p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            printf '  --list        print the selection and stop\n'
            printf '  --jobs N      tests to run at once within each suite\n'
            printf '  --base REF    what --changed diffs against\n'
            exit 0 ;;
        -*) echo "unknown argument: $1" >&2; exit 2 ;;
        # A path given here stands in for one git would have reported, so the
        # map can be asked what it does with a path without the answer
        # depending on what happens to be uncommitted.
        *) given_paths+=("$1") ;;
    esac
    shift
done

if [ "$lane" != changed ] && [ "${#given_paths[@]}" -gt 0 ]; then
    echo "paths only mean something with --changed: ${given_paths[*]}" >&2
    exit 2
fi

all_suites=()
for f in test/*.bats; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .bats)"
    case "$PRIVILEGED" in *" $name "*) continue ;; esac
    all_suites+=("$name")
done
[ "${#all_suites[@]}" -gt 0 ] || { echo "found no confined suites under test/" >&2; exit 1; }

# Within-file parallelism is bats' own, and it needs flock. Without it bats
# exits before running anything, so the fallback is stated rather than left to
# look like a broken suite. The size of it is decided after the selection,
# below, because it depends on how many suites there are.
if command -v flock >/dev/null 2>&1; then
    can_parallelize=1
else
    can_parallelize=0
fi

selected=()
changed_paths=()
if [ "$lane" = changed ]; then
    if [ "${#given_paths[@]}" -gt 0 ]; then
        changed_paths=("${given_paths[@]}")
    else
        if [ -z "$base" ]; then
            for candidate in origin/development development origin/main main; do
                if git rev-parse --verify --quiet "$candidate" >/dev/null; then
                    base="$candidate"
                    break
                fi
            done
        fi
        # Committed work plus what is still in the working tree, including
        # files git has never seen: iteration happens before a commit, and a
        # lane that only saw committed changes would report on the wrong thing.
        mapfile -t changed_paths < <(
            {
                [ -z "$base" ] || git diff --name-only \
                    "$(git merge-base "$base" HEAD 2>/dev/null || echo "$base")" 2>/dev/null
                git diff --name-only HEAD 2>/dev/null
                git ls-files --others --exclude-standard 2>/dev/null
            } | sort -u
        )
    fi

    wanted=" "
    for p in "${changed_paths[@]}"; do
        [ -n "$p" ] || continue
        for s in $(suites_for "$p"); do
            [ "$s" != ALL ] || { wanted=ALL; break 2; }
            case "$wanted" in *" $s "*) ;; *) wanted="$wanted$s " ;; esac
        done
    done
    if [ "$wanted" = ALL ]; then
        selected=("${all_suites[@]}")
    else
        for s in "${all_suites[@]}"; do
            case "$wanted" in *" $s "*) selected+=("$s") ;; esac
        done
    fi
else
    selected=("${all_suites[@]}")
fi

skipped=()
for s in "${all_suites[@]}"; do
    for t in ${selected[@]+"${selected[@]}"}; do [ "$t" = "$s" ] && continue 2; done
    skipped+=("$s")
done

# Which lane ran, before anything else, because the whole point of having two
# is that a run can be read back later without guessing which one it was. To
# stderr, so --list's stdout is the suite names and nothing else.
# How much concurrency to actually ask for.
#
# Every selected suite runs at once, so what lands on the machine is
# suites x jobs. Asking each suite for `nproc` made that ten times the cores
# on a ten-core box, and #295 is what that cost: the tests that wait on a
# bounded deadline - a pty reaching raw mode, a shipper polling, an audit
# finishing - blow through it on a machine that oversubscribed, and fail for
# the load rather than for the thing they check.
#
# Oversubscription still helps, because these tests fork more than they
# compute. It is a property of the whole run rather than of each suite, so it
# is budgeted once and divided: roughly twice the cores, in total.
if [ -z "$jobs" ]; then
    if [ "$can_parallelize" = 1 ] && [ "${#selected[@]}" -gt 0 ]; then
        cores="$(nproc 2>/dev/null || echo 4)"
        budget=$(( cores * 2 ))
        jobs=$(( (budget + ${#selected[@]} - 1) / ${#selected[@]} ))
        [ "$jobs" -ge 1 ] || jobs=1
    else
        jobs=1
    fi
fi
bats_flags=()
[ "$jobs" -gt 1 ] && bats_flags=(--jobs "$jobs" --no-parallelize-across-files)

{
    if [ "$lane" = changed ]; then
        printf 'lane: CHANGED - %d of %d confined suites, from %d changed path(s)\n' \
            "${#selected[@]}" "${#all_suites[@]}" "${#changed_paths[@]}"
        [ "${#skipped[@]}" -eq 0 ] || printf '      not run: %s\n' "${skipped[*]}"
        printf '      An iteration check. NOT the pull-request gate - for that run\n'
        printf '      test/run-confined.sh with no arguments.\n'
    else
        printf 'lane: ALL - every confined suite (the pull-request gate)\n'
        printf '      not run: runtime, ci-runner - they need Docker and a real runner.\n'
    fi
    [ "$list_only" = 1 ] || printf '      %d test(s) at a time within each suite, %d suites at once\n' \
        "$jobs" "${#selected[@]}"
    printf '\n'
} >&2

if [ "$list_only" = 1 ]; then
    [ "${#selected[@]}" -eq 0 ] || printf '%s\n' "${selected[@]}"
    exit 0
fi

if [ "${#selected[@]}" -eq 0 ]; then
    echo "nothing to run: no changed path maps to a confined suite"
    exit 0
fi

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
for s in "${selected[@]}"; do
    ( bats ${bats_flags[@]+"${bats_flags[@]}"} "test/$s.bats" > "$out/$s" 2>&1
      printf '%s' "$?" > "$out/$s.status" ) &
done
wait

# Counted from the TAP output rather than taken from the exit status alone: a
# suite that fails to run at all - a syntax error, or duplicate test names,
# which bats refuses outright - exits nonzero having run nothing, and reporting
# that as "0 failures" is how a green board comes to mean nothing.
#
# Skips are counted and shown separately because bats emits one as `ok N ...
# # skip`, so a test that decided not to run is indistinguishable from one that
# passed. Several here skip on host state - an empty /opt/dejima, a missing
# tool - so the column is the only thing that says how much of the suite the
# number above actually covers.
failed=0
printf '%-16s %6s %8s %8s\n' suite ran skipped failed
for s in "${selected[@]}"; do
    emitted="$(grep -cE '^(ok|not ok)' "$out/$s")"
    n_skipped="$(grep -cE '^ok [0-9]+ .* # skip' "$out/$s")"
    bad="$(grep -cE '^not ok' "$out/$s")"
    status="$(cat "$out/$s.status" 2>/dev/null || echo 1)"
    printf '%-16s %6s %8s %8s' "$s" "$(( emitted - n_skipped ))" "$n_skipped" "$bad"
    if [ "$emitted" -eq 0 ]; then
        printf '   <- ran nothing\n'
        failed=1
    elif [ "$bad" -gt 0 ] || [ "$status" -ne 0 ]; then
        printf '\n'
        failed=1
    else
        printf '\n'
    fi
done

for s in "${selected[@]}"; do
    grep -hE '^ok [0-9]+ .* # skip' "$out/$s" | sed -E "s/^ok [0-9]+ /    $s: /"
done | { grep . && echo "    (skipped, so the counts above do not cover them)"; } || true

if [ "$failed" -ne 0 ]; then
    echo
    for s in "${selected[@]}"; do
        emitted="$(grep -cE '^(ok|not ok)' "$out/$s")"
        bad="$(grep -cE '^not ok' "$out/$s")"
        { [ "$bad" -gt 0 ] || [ "$emitted" -eq 0 ]; } || continue
        echo "--- $s"
        if [ "$emitted" -eq 0 ]; then
            head -20 "$out/$s"
        else
            grep -E '^not ok' -A 20 "$out/$s"
        fi
        echo
    done
fi
exit "$failed"
