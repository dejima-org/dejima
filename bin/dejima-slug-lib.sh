# Shared library: the ~/.claude/projects slug scheme, and which slugs belong
# to a given workspace. Sourced by bin/dejima (to decide what to mount) and
# bin/dejima-audit (to decide what counts as a cross-project write). Not on
# PATH and not executable.
#
# One definition, because the two callers must not disagree. A slug the mount
# exposes but the audit treats as foreign produces a finding on every ordinary
# session; a slug the audit treats as the workspace's own but the mount does
# not expose is a hole that nothing reports.

# Claude Code's own project key: the absolute cwd with every non-alphanumeric
# replaced by a dash. Matches docker/log-shipper.sh's Loki key and
# dejima-project-lib.sh's project_slug, which cannot source this file (one
# runs inside the container, the other is a separate library).
ws_slug() { printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }

# The slugs belonging to $1: its own, plus one per live git worktree nested
# underneath it. One per line, sorted, no duplicates.
#
# Derived from real worktree paths rather than from the slug string, and that
# is the whole point of the function. Slugs cannot distinguish a child from a
# sibling: `/w/proj/wt1` and `/w/proj-wt1` both slug to `-w-proj-wt1`, so a
# `$slug-*` glob matches any sibling project whose directory name merely
# extends this one's - on a host with `proj` and `proj-ci` checked out side by
# side, `proj-ci` reads as part of `proj`. A path test cannot make that
# mistake, because a sibling is not under the workspace directory.
#
# Listing from a worktree names the main checkout and its siblings too. Those
# are not under $1, so they drop out here: launching against a worktree
# exposes that worktree and nothing else, which is correct.
workspace_slugs() {
    local ws="$1" wt
    ws="${ws%/}"
    ws_slug "$ws"
    printf '\n'
    # A path containing a newline splits into two lines that name no real
    # directory, so both fail the -d test below rather than being parsed as
    # some other worktree. git has no unambiguous non-`-z` output here.
    git -C "$ws" worktree list --porcelain 2>/dev/null \
        | sed -n 's/^worktree //p' \
        | while IFS= read -r wt; do
            case "$wt" in
                "$ws"/*) ;;
                *) continue ;;
            esac
            [ -d "$wt" ] || continue
            ws_slug "$wt"
            printf '\n'
        done
}

# Every slug in workspace_slugs, sorted and deduplicated.
workspace_slugs_sorted() { workspace_slugs "$1" | sort -u; }
