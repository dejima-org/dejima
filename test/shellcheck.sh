#!/bin/bash
# Every shell script in the repo, run through shellcheck. Used by the CI job
# and by test/static.bats, so the two cannot disagree about what is covered.
#
# The list is discovered, not enumerated: a script added under bin/, hooks/,
# docker/, test/ or a forge's bin/ is covered the day it lands, which is the only
# version of this that stays true. Discovery is by shebang rather than by
# extension, because most of this repo's scripts have no extension.
#
# Prints the file list and exits 0 when given --list, so static.bats can
# assert what is covered without needing shellcheck installed.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

list_scripts() {
    cd "$root"
    {
        ls bin/dejima bin/dejima-* bin/harness/*.sh 2>/dev/null || true
        ls hooks/*.sh docker/*.sh install.sh 2>/dev/null || true
        ls forges/*/bin/* 2>/dev/null || true
        # test/, for the reason .dejima.md gives for being careful what goes
        # there: CI checks the commit out on a host and runs it, so a helper
        # in a test file is code executing outside the sandbox. That makes
        # these the last scripts that should go unchecked, not the first -
        # and leaving them out hid a real fault in the release gate itself.
        ls test/*.sh 2>/dev/null || true
    } | sort -u | while read -r f; do
        [ -f "$f" ] || continue
        # Sourced fragments are not executed, so they carry no shebang and the
        # discovery below would drop them - silently, which is the worst
        # version of that. Harness plugins are one kind; docker/ has two more,
        # and they are not incidental: caps-lib.sh holds the drop that decides
        # what a session's capability set is, and fixed-domains.sh is the seam
        # keeping the DNS allowlist and the ipset allowlist from drifting.
        #
        # Matched by directory rather than by name, because a list is a thing
        # to forget to add to. Everything under docker/ is in the trusted
        # computing base; the -s bash below tells shellcheck what these are.
        case "$f" in bin/harness/*.sh|docker/*.sh) printf '%s\n' "$f"; continue ;; esac
        head -1 "$f" | grep -qE '^#!.*(bash|sh)' && printf '%s\n' "$f"
    done
}

if [ "${1:-}" = "--list" ]; then
    list_scripts
    exit 0
fi

mapfile -t scripts < <(list_scripts)
[ "${#scripts[@]}" -gt 0 ] || { echo "found no shell scripts to check" >&2; exit 1; }

cd "$root"

# Said plainly rather than left to `exec` to fail with "not found", which reads
# as a broken script rather than a missing tool - and, on a nonzero exit nobody
# reads closely, as a check that ran.
if ! command -v shellcheck >/dev/null 2>&1; then
    echo "shellcheck is not installed, so nothing was checked." >&2
    echo >&2
    echo "It is declared in .dejima/dependencies. In a sandbox that predates" >&2
    echo "that declaration, approve it and relaunch so the image is rebuilt:" >&2
    echo >&2
    echo "  dejima-project approve" >&2
    echo >&2
    echo "Report the suite as not run rather than as passing." >&2
    exit 127
fi

# -S warning: info and style are largely taste, and a check whose output gets
# skimmed is not a check. Severities and the disabled classes are in
# .shellcheckrc, beside the reasoning for each.
exec shellcheck -S warning -s bash "${scripts[@]}"
