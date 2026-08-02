#!/usr/bin/env bats
# Providers are data, not code. These tests are mostly about what a malformed
# or over-reaching manifest is NOT allowed to do.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    LIB="$REPO_ROOT/bin/dejima-provider-lib.sh"
    CONFIG_DIR="$(mktemp -d)"
    export DEJIMA_CONFIG_DIR="$CONFIG_DIR"
}
teardown() { rm -rf "$CONFIG_DIR" ${FAKE_ROOT:+"$FAKE_ROOT"}; }

lib() { bash -c 'source "$1"; shift; "$@"' _ "$LIB" "$@"; }

@test "every shipped manifest validates" {
    for axis in forge workflow harness; do
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            run lib manifest_validate "$axis" "$name"
            [ "$status" -eq 0 ] || { echo "$axis/$name: $output"; return 1; }
        done < <(lib provider_list "$axis")
    done
}

@test "each axis ships at least one provider" {
    for axis in forge workflow harness; do
        [ -n "$(lib provider_list "$axis")" ] || { echo "no $axis providers"; return 1; }
    done
}

@test "an unknown manifest key is fatal" {
    FAKE_ROOT="$(mktemp -d)"
    mkdir -p "$FAKE_ROOT/forges/bogus"
    printf 'capabilities = pr\nnonesuch = 1\n' > "$FAKE_ROOT/forges/bogus/forge.conf"
    run env DEJIMA_PROVIDER_ROOT="$FAKE_ROOT" \
        bash -c 'source "$1"; manifest_validate forge bogus' _ "$LIB"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown key"* ]]
}

@test "a manifest is parsed, never sourced" {
    FAKE_ROOT="$(mktemp -d)"
    mkdir -p "$FAKE_ROOT/forges/evil"
    printf 'capabilities = pr\npr_command = $(touch %s/PWNED)\n' "$FAKE_ROOT" \
        > "$FAKE_ROOT/forges/evil/forge.conf"
    run env DEJIMA_PROVIDER_ROOT="$FAKE_ROOT" \
        bash -c 'source "$1"; manifest_validate forge evil' _ "$LIB"
    [ ! -e "$FAKE_ROOT/PWNED" ]
    # And the value is refused outright rather than merely not executed.
    [ "$status" -ne 0 ]
}

@test "provider_dir refuses a name that escapes the axis directory" {
    for bad in ".." "../../etc" "a/b" "" "."; do
        run lib provider_dir forge "$bad"
        [ "$status" -ne 0 ] || { echo "accepted provider name '$bad'"; return 1; }
    done
}

@test "manifest_get returns a value and refuses an unknown key" {
    run lib manifest_get forge gitea pr_command
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    run lib manifest_get forge gitea nonesuch
    [ "$status" -ne 0 ]
}
