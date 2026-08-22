#!/bin/bash
# Every shell script in the repo, run through shellcheck. Used by the CI job
# and by test/static.bats, so the two cannot disagree about what is covered.
#
# The list is discovered, not enumerated: a script added under bin/, hooks/,
# docker/ or a forge's bin/ is covered the day it lands, which is the only
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
    } | sort -u | while read -r f; do
        [ -f "$f" ] || continue
        # Harness plugins are sourced, not executed, so they carry no shebang
        # and the discovery below would drop them - silently, which is the
        # worst version of that. They are in the trusted computing base, so
        # they are included by name and the -s bash below tells shellcheck
        # what they are.
        case "$f" in bin/harness/*.sh) printf '%s\n' "$f"; continue ;; esac
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
# -S warning: info and style are largely taste, and a check whose output gets
# skimmed is not a check. Severities and the disabled classes are in
# .shellcheckrc, beside the reasoning for each.
exec shellcheck -S warning -s bash "${scripts[@]}"
