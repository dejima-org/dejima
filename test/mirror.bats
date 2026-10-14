#!/usr/bin/env bats
# mirror/github-mirror.sh: what the GitHub copy is rewritten to, and how its
# main is built. Nothing here pushes; --dry-run stops before the push, which
# is the one line these tests leave to the operator's first sync.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    MIRROR="$REPO_ROOT/mirror/github-mirror.sh"
    T="$(mktemp -d)"
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com \
        GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

    # The forge: this tree's docs, as one commit on main.
    git init -q -b main "$T/forge"
    cp -r "$REPO_ROOT"/*.md "$REPO_ROOT/docs" "$REPO_ROOT/assets" "$T/forge/"
    git -C "$T/forge" add -A
    git -C "$T/forge" commit -qm base
    git init -q --bare "$T/github.git"
    export MIRROR_SOURCE="$T/forge" MIRROR_TARGET="$T/github.git" MIRROR_STATE="$T/state"
}

teardown() {
    rm -rf "$T"
}

mirrored() {
    git -C "$MIRROR_STATE" rev-parse refs/mirror/next
}

@test "the mirror's README follows the reader's colour scheme" {
    "$MIRROR" --transform "$T/forge"
    local readme="$T/forge/README.md"
    grep -qF '<source media="(prefers-color-scheme: dark)" srcset="assets/dejima-wordmark-darkmode.png">' "$readme"
    grep -qF '<img src="assets/dejima-wordmark-lightmode.png" alt="dejima" height="72"></picture>' "$readme"
}

@test "the mirror's README says it takes no issues or pull requests, above the fold" {
    "$MIRROR" --transform "$T/forge"
    local notice heading
    notice="$(grep -n 'This is a read-only mirror' "$T/forge/README.md" | cut -d: -f1)"
    heading="$(grep -n '^## ' "$T/forge/README.md" | head -1 | cut -d: -f1)"
    [ -n "$notice" ] && [ "$notice" -lt "$heading" ]
    grep -q 'issues and pull requests are not accepted here' "$T/forge/README.md"
}

@test "repository links move to GitHub and issue links stay on the forge" {
    grep -q 'gitbox.branderson.io/dejima/dejima/\(issues\|pulls\)/' "$T/forge/CHANGELOG.md"
    "$MIRROR" --transform "$T/forge"
    cd "$T/forge"
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

@test "a README the transform no longer recognises stops the mirror" {
    sed -i 's/dejima-wordmark-darkmode.png/renamed.png/' "$T/forge/README.md"
    run "$MIRROR" --transform "$T/forge"
    [ "$status" -ne 0 ]
    [[ "$output" == *"wordmark tag was not found"* ]]
}

@test "the mirror commit sits on the forge's main, and the same input makes the same commit" {
    run "$MIRROR" --dry-run
    [ "$status" -eq 0 ]
    local first src
    first="$(mirrored)"
    src="$(git -C "$T/forge" rev-parse main)"
    [ "$(git -C "$MIRROR_STATE" rev-parse "$first^1")" = "$src" ]
    run git -C "$MIRROR_STATE" rev-parse -q --verify "$first^2"
    [ "$status" -ne 0 ]

    MIRROR_STATE="$T/state2" run "$MIRROR" --dry-run
    [ "$(git -C "$T/state2" rev-parse refs/mirror/next)" = "$first" ]
}

@test "each sync fast-forwards the previous mirror commit" {
    "$MIRROR" --dry-run
    local prev
    prev="$(mirrored)"
    git -C "$MIRROR_TARGET" fetch -q "$MIRROR_STATE" "$prev:refs/heads/main"

    echo change >> "$T/forge/docs/ci.md"
    git -C "$T/forge" commit -qam change
    "$MIRROR" --dry-run
    local next
    next="$(mirrored)"
    [ "$(git -C "$MIRROR_STATE" rev-parse "$next^1")" = "$(git -C "$T/forge" rev-parse main)" ]
    [ "$(git -C "$MIRROR_STATE" rev-parse "$next^2")" = "$prev" ]

    git -C "$MIRROR_TARGET" fetch -q "$MIRROR_STATE" "+$next:refs/heads/main"
    run "$MIRROR" --dry-run
    [[ "$output" == *"already at"* ]]
}

@test "only tags on main are mirrored" {
    git -C "$T/forge" tag released
    git -C "$T/forge" checkout -qb development
    git -C "$T/forge" commit -q --allow-empty -m unreleased
    git -C "$T/forge" tag unreleased
    run "$MIRROR" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"tag released"* ]]
    [[ "$output" != *"tag unreleased"* ]]
}
