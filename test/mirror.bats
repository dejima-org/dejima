#!/usr/bin/env bats
# mirror/github-mirror.sh: what the GitHub copies are rewritten to, and how
# their main is built. Nothing here pushes; --dry-run stops before the push, which
# is the one line these tests leave to the operator's first sync.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    MIRROR="$REPO_ROOT/mirror/github-mirror.sh"
    T="$(mktemp -d)"
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com \
        GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

    # The forge: this tree's docs, as one commit on main.
    F="$T/forge/dejima"
    git init -q -b main "$F"
    cp -r "$REPO_ROOT"/*.md "$REPO_ROOT/docs" "$REPO_ROOT/assets" "$F/"
    git -C "$F" add -A
    git -C "$F" commit -qm base
    mkdir "$T/github"
    git init -q --bare "$T/github/dejima"
    export MIRROR_SOURCE="$T/forge" MIRROR_TARGET="$T/github" MIRROR_STATE="$T/state" \
        MIRROR_REPOS=dejima
    unset MIRROR_ORG
}

teardown() {
    rm -rf "$T"
}

mirrored() {
    git -C "$MIRROR_STATE/dejima.git" rev-parse refs/mirror/next
}

@test "the mirror's README follows the reader's colour scheme" {
    "$MIRROR" --transform "$F"
    local readme="$F/README.md"
    grep -qF '<source media="(prefers-color-scheme: dark)" srcset="assets/dejima-wordmark-darkmode.png">' "$readme"
    grep -qF '<img src="assets/dejima-wordmark-lightmode.png" alt="dejima" height="72"></picture>' "$readme"
}

@test "the mirror's README says it takes no issues or pull requests, above the fold" {
    "$MIRROR" --transform "$F"
    local notice heading
    notice="$(grep -n 'This is a read-only mirror' "$F/README.md" | cut -d: -f1)"
    heading="$(grep -n '^## ' "$F/README.md" | head -1 | cut -d: -f1)"
    [ -n "$notice" ] && [ "$notice" -lt "$heading" ]
    grep -q 'issues and pull requests are not accepted here' "$F/README.md"
}

@test "repository links move to GitHub and issue links stay on the forge" {
    grep -q 'gitbox.branderson.io/dejima/dejima/\(issues\|pulls\)/' "$F/CHANGELOG.md"
    "$MIRROR" --transform "$F"
    cd "$F"
    run grep -rhoE 'https://gitbox\.branderson\.io/dejima/[^)]*' --include='*.md' .
    local link
    for link in "${lines[@]}"; do
        [[ "$link" =~ ^https://gitbox\.branderson\.io/dejima/dejima/(issues|pulls)/[0-9]+$ ]] \
            || { echo "still on the forge: $link"; return 1; }
    done
    grep -qF '](https://github.com/dejima-org/dejima)' README.md
    grep -qF '(https://github.com/dejima-org/dejima-guard/blob/main/SECURITY.md)' docs/threat-model.md
    ! grep -rq 'github.com/dejima-org/[^)]*/src/branch/' --include='*.md' .
}

@test "transforming twice changes nothing, so a clone of the mirror passes this suite" {
    "$MIRROR" --transform "$F"
    cp -r "$F" "$T/once"
    "$MIRROR" --transform "$F"
    diff -r -x .git "$T/once" "$F"
}

@test "a README the transform no longer recognises stops the mirror" {
    sed -i 's/dejima-wordmark-darkmode.png/renamed.png/' "$F/README.md"
    run "$MIRROR" --transform "$F"
    [ "$status" -ne 0 ]
    [[ "$output" == *"wordmark tag was not found"* ]]
}

@test "the mirror commit sits on the forge's main, and the same input makes the same commit" {
    run "$MIRROR" --dry-run
    [ "$status" -eq 0 ]
    local first src
    first="$(mirrored)"
    src="$(git -C "$F" rev-parse main)"
    [ "$(git -C "$MIRROR_STATE/dejima.git" rev-parse "$first^1")" = "$src" ]
    run git -C "$MIRROR_STATE/dejima.git" rev-parse -q --verify "$first^2"
    [ "$status" -ne 0 ]

    MIRROR_STATE="$T/state2" run "$MIRROR" --dry-run
    [ "$(git -C "$T/state2/dejima.git" rev-parse refs/mirror/next)" = "$first" ]
}

@test "each sync fast-forwards the previous mirror commit" {
    "$MIRROR" --dry-run
    local prev
    prev="$(mirrored)"
    git -C "$MIRROR_TARGET/dejima" fetch -q "$MIRROR_STATE/dejima.git" "$prev:refs/heads/main"

    echo change >> "$F/docs/ci.md"
    git -C "$F" commit -qam change
    "$MIRROR" --dry-run
    local next
    next="$(mirrored)"
    [ "$(git -C "$MIRROR_STATE/dejima.git" rev-parse "$next^1")" = "$(git -C "$F" rev-parse main)" ]
    [ "$(git -C "$MIRROR_STATE/dejima.git" rev-parse "$next^2")" = "$prev" ]

    git -C "$MIRROR_TARGET/dejima" fetch -q "$MIRROR_STATE/dejima.git" "+$next:refs/heads/main"
    run "$MIRROR" --dry-run
    [[ "$output" == *"already at"* ]]
}

@test "only tags on main are mirrored" {
    git -C "$F" tag released
    git -C "$F" checkout -qb development
    git -C "$F" commit -q --allow-empty -m unreleased
    git -C "$F" tag unreleased
    run "$MIRROR" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"tag released"* ]]
    [[ "$output" != *"tag unreleased"* ]]
}

@test "clone URLs in code move too, and a repo with no wordmark gets the notice under its title" {
    # Assembled, so the mirror's copy of this file is not itself rewritten.
    local B="$T/forge/dejima-badge" forge="https://gitbox.branderson.io"
    git init -q -b main "$B"
    printf '# Developed in dejima\n\nSee [dejima](%s/dejima/dejima).\n\n## Use\n\n    curl -fLO %s/dejima/dejima-badge/raw/branch/main/dejima-badge.svg\n' "$forge" "$forge" > "$B/README.md"
    printf '#!/bin/sh\nURL=${URL:-%s/dejima/dejima.git}\n' "$forge" > "$B/clone"
    git -C "$B" add -A
    "$MIRROR" --transform "$B"
    [ "$(sed -n 3p "$B/README.md")" = '> **This is a read-only mirror.** dejima is developed on a private forge,' ]
    grep -qF 'https://github.com/dejima-org/dejima-badge/raw/main/dejima-badge.svg' "$B/README.md"
    grep -qF 'URL=${URL:-https://github.com/dejima-org/dejima.git}' "$B/clone"
}

@test "a repository that fails does not stop the others, and the run says which" {
    MIRROR_REPOS="missing dejima" run "$MIRROR" --dry-run
    [ "$status" -ne 0 ]
    [[ "$output" == *"dejima: main is "* ]]
    [[ "$output" == *"failed: missing"* ]]
}

@test "a repository with no forge links still gets its notice" {
    local B="$T/forge/plain"
    git init -q -b main "$B"
    printf '# Plain\n\nNothing to rewrite.\n' > "$B/README.md"
    git -C "$B" add -A
    "$MIRROR" --transform "$B"
    grep -q '^> \*\*This is a read-only mirror' "$B/README.md"
}
