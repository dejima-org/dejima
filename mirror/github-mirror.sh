#!/usr/bin/env bash
# Publishes main and its release tags to a read-only GitHub mirror (#209).
#
#   MIRROR_SOURCE=<forge clone URL> mirror/github-mirror.sh    sync once
#   ... mirror/github-mirror.sh --dry-run                      build and print, push nothing
#   mirror/github-mirror.sh --settings                         configure the GitHub repo (needs gh)
#   mirror/github-mirror.sh --transform DIR                    rewrite a checkout in place
#
# Runs on the host, never in a session: a sandbox may push only to its own
# forge, and this needs push access to GitHub.
#
# The GitHub copy is not byte-for-byte. Its main is one extra commit on top of
# the forge's main, whose tree is the forge's with the rewrites in transform()
# applied, and whose parents are the forge commit and the previous mirror
# commit. So every forge SHA is in the mirror unchanged, and each sync is a
# fast-forward for anyone tracking it. Tags are pushed as they are, pointing at
# the untransformed forge commits.
#
# Environment:
#   MIRROR_SOURCE  clone URL of the forge repository (required to sync)
#   MIRROR_REPO    GitHub owner/name, default dejima-org/dejima
#   MIRROR_TARGET  push URL, default git@github.com:$MIRROR_REPO.git
#   MIRROR_STATE   working bare repository, default ~/.cache/dejima-github-mirror
set -euo pipefail

MIRROR_REPO="${MIRROR_REPO:-dejima-org/dejima}"
MIRROR_TARGET="${MIRROR_TARGET:-git@github.com:$MIRROR_REPO.git}"
MIRROR_STATE="${MIRROR_STATE:-${XDG_CACHE_HOME:-$HOME/.cache}/dejima-github-mirror}"

die() { echo "github-mirror: $*" >&2; exit 1; }

WORK=""
cleanup() {
    [ -n "$WORK" ] || return 0
    git -C "$MIRROR_STATE" worktree remove --force "$WORK" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

# Rewrites the reader-facing files of a checkout for GitHub. Each rewrite is
# checked, so a README that drifted away from what this expects stops the
# mirror instead of publishing the forge's version.
transform() {
    local dir="$1"
    local readme="$dir/README.md"
    [ -f "$readme" ] || die "no README.md in $dir"

    # Repository links move to the org on GitHub; issue and pull request links
    # stay on the forge, which is the only place those exist. Gitea's
    # /src/branch/ is GitHub's /blob/.
    (cd "$dir" && git grep -lzF 'gitbox.branderson.io/dejima/' -- '*.md' | xargs -0r perl -pi -e '
        s{https://gitbox\.branderson\.io/dejima/([\w.-]++)(?!/(?:issues|pulls)/)}{https://github.com/dejima-org/$1}g;
        s{(https://github\.com/dejima-org/[\w.-]+)/src/branch/}{$1/blob/}g;
    ')

    # GitHub follows the reader's light/dark setting through <picture>, which
    # the forge cannot; see the comment above the tag in README.md.
    perl -0pi -e '
        s{<img src="assets/dejima-wordmark-darkmode\.png" alt="dejima" height="72">}
         {<picture><source media="(prefers-color-scheme: dark)" srcset="assets/dejima-wordmark-darkmode.png"><img src="assets/dejima-wordmark-lightmode.png" alt="dejima" height="72"></picture>}
    ' "$readme"
    grep -q '<picture>' "$readme" || die "README.md: the wordmark tag was not found"

    # The first thing a visitor to a mirror does is open a pull request.
    perl -0pi -e '
        s{^---\n}{---\n\n> **This is a read-only mirror.** dejima is developed on a private forge,\n> and issues and pull requests are not accepted here. See\n> [CONTRIBUTING.md](CONTRIBUTING.md).\n}m
    ' "$readme"
    grep -q '^> \*\*This is a read-only mirror' "$readme" \
        || die "README.md: no --- line to put the mirror notice under"
}

# Issues, pull requests and Actions off. Settings rather than content, so a
# sync does not reapply them; run once after creating the repository.
settings() {
    command -v gh >/dev/null || die "--settings needs the gh CLI"
    gh api -X PATCH "repos/$MIRROR_REPO" --silent \
        -F has_issues=false -F has_pull_requests=false -F has_projects=false \
        -F has_wiki=false -F has_discussions=false
    gh api -X PUT "repos/$MIRROR_REPO/actions/permissions" --silent -F enabled=false
}

sync() {
    [ -n "${MIRROR_SOURCE:-}" ] || die "MIRROR_SOURCE is not set"
    local git=(git -C "$MIRROR_STATE")
    [ -d "$MIRROR_STATE" ] || git init -q --bare "$MIRROR_STATE"

    "${git[@]}" fetch -q --no-tags --prune "$MIRROR_SOURCE" \
        '+refs/heads/main:refs/source/main' '+refs/tags/*:refs/source/tags/*'
    local src prev=""
    src="$("${git[@]}" rev-parse refs/source/main)"

    # An absent main (exit 2) is a first run; anything else is a real failure.
    local rc=0
    git ls-remote -q --exit-code "$MIRROR_TARGET" refs/heads/main >/dev/null || rc=$?
    if [ "$rc" -eq 0 ]; then
        "${git[@]}" fetch -q --no-tags "$MIRROR_TARGET" '+refs/heads/main:refs/mirror/main'
        prev="$("${git[@]}" rev-parse refs/mirror/main)"
    elif [ "$rc" -ne 2 ]; then
        die "cannot read $MIRROR_TARGET"
    fi

    WORK="$(mktemp -d)"
    "${git[@]}" worktree add -q --detach "$WORK" "$src"
    transform "$WORK"
    git -C "$WORK" add -A
    local tree
    tree="$(git -C "$WORK" write-tree)"

    if [ -n "$prev" ] && [ "$("${git[@]}" rev-parse "$prev^1")" = "$src" ] \
        && [ "$("${git[@]}" rev-parse "$prev^{tree}")" = "$tree" ]; then
        echo "github-mirror: already at ${src:0:12}"
    else
        # The forge commit's committer and date, so the same input always
        # makes the same commit.
        local name email date commit
        IFS=$'\t' read -r name email date < <("${git[@]}" log -1 --format='%cn%x09%ce%x09%cI' "$src")
        commit="$(GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$email" GIT_AUTHOR_DATE="$date" \
            GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email" GIT_COMMITTER_DATE="$date" \
            "${git[@]}" commit-tree "$tree" -p "$src" ${prev:+-p "$prev"} \
            -m "Mirror ${src:0:12} for GitHub" \
            -m "Forge links and the README header rewritten by mirror/github-mirror.sh.")"
        "${git[@]}" update-ref refs/mirror/next "$commit"
        [ -n "$DRY_RUN" ] || "${git[@]}" push -q "$MIRROR_TARGET" "$commit:refs/heads/main"
        echo "github-mirror: main is ${src:0:12} as ${commit:0:12}"
    fi

    # Only tags on main: one on another branch would publish unreleased work.
    local ref refspecs=()
    while IFS= read -r ref; do
        if "${git[@]}" merge-base --is-ancestor "$ref" "$src"; then
            refspecs+=("$ref:refs/tags/${ref#refs/source/tags/}")
        fi
    done < <("${git[@]}" for-each-ref --format='%(refname)' refs/source/tags/)
    [ "${#refspecs[@]}" -gt 0 ] || return 0
    printf 'github-mirror: tag %s\n' "${refspecs[@]#*:refs/tags/}"
    [ -n "$DRY_RUN" ] || "${git[@]}" push -q "$MIRROR_TARGET" "${refspecs[@]}"
}

DRY_RUN=""
case "${1:-}" in
    "")          sync ;;
    --dry-run)   DRY_RUN=1; sync ;;
    --settings)  settings ;;
    --transform) [ -n "${2:-}" ] || die "--transform needs a directory"; transform "$2" ;;
    *)           sed -n '2,8p' "$0" >&2; exit 2 ;;
esac
